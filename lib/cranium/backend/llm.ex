defmodule Cranium.Backend.LLM do
  @moduledoc """
  Behaviour for LLM inference backends.

  Implementations manage streaming chat completions. The backend spawns
  a process that sends tagged messages to the caller as SSE events arrive:

  - `{:llm_text, text}` — text content chunk
  - `{:llm_tool_use, %{id: id, name: name, input: input}}` — tool call
  - `{:llm_usage, %{input_tokens: n, output_tokens: n, ...}}` — token counts
  - `{:llm_stop, reason}` — inference complete ("end_turn", "tool_use", etc.)

  The returned pid can be monitored for crash detection.
  """

  @doc """
  Start a streaming chat completion.

  Returns `{:ok, pid}` where pid is a process that will send SSE events
  as tagged messages to the calling process.

  ## Options

  - `:system` — system prompt string
  - `:tools` — list of tool definitions
  - `:model` — model identifier override
  - `:max_tokens` — maximum output tokens
  """
  @callback stream_chat(messages :: list(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}
end

defmodule Cranium.Backend.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API backend.

  Connects to the Anthropic API via SSE streaming, parsing server-sent
  events and forwarding them as tagged messages.

  ## SSE Events

  The Anthropic streaming API sends these event types:
  - `message_start` — initial message metadata
  - `content_block_start` — new content block (text or tool_use)
  - `content_block_delta` — incremental content
  - `content_block_stop` — block complete
  - `message_delta` — stop_reason, usage updates
  - `message_stop` — message complete

  This backend parses these into the simplified tagged messages defined
  by the LLM behaviour.
  """

  @behaviour Cranium.Backend.LLM

  require Logger

  alias Cranium.Backend.SSE

  @api_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-opus-4-6"
  @default_max_tokens 8192

  @impl true
  def stream_chat(messages, opts) do
    caller = self()

    pid =
      spawn_link(fn ->
        do_stream(caller, messages, opts)
      end)

    {:ok, pid}
  end

  defp do_stream(caller, messages, opts) do
    api_key = Keyword.get(opts, :api_key) || api_key()
    model = Keyword.get(opts, :model) || model()
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])

    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: messages,
        stream: true,
        cache_control: %{type: "ephemeral", ttl: "1h"}
      }
      |> maybe_add(:system, system)
      |> maybe_add(:tools, tools)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    # Accumulate SSE state and tool_use blocks across the stream
    sse_state = SSE.new()
    tool_acc = %{}

    stream_fn = fn {:data, data}, {req, resp} ->
      {events, new_sse} =
        Process.get(:sse_state, sse_state) |> SSE.parse(data)

      new_tool_acc =
        Process.get(:tool_acc, tool_acc)
        |> then(fn acc -> dispatch_events(caller, events, acc) end)

      Process.put(:sse_state, new_sse)
      Process.put(:tool_acc, new_tool_acc)
      {:cont, {req, resp}}
    end

    # First, try a non-streaming request to check for auth/validation errors.
    # If the response is 200, re-request with streaming. This avoids the
    # problem of `into:` consuming error response bodies.
    #
    # Actually — just use `into:` and handle errors by accumulating the
    # error body in the streaming function.
    error_acc = []

    stream_fn_with_error = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        stream_fn.({:data, data}, {req, resp})
      else
        Process.put(:error_body, [data | Process.get(:error_body, error_acc)])
        {:cont, {req, resp}}
      end
    end

    case Req.post(@api_url,
           json: body,
           headers: headers,
           receive_timeout: 120_000,
           into: stream_fn_with_error
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} ->
        error_body =
          Process.get(:error_body, [])
          |> Enum.reverse()
          |> IO.iodata_to_binary()
          |> try_decode_json()

        Logger.error("Anthropic API error", status: status, body: inspect(error_body))
        send(caller, {:llm_stop, {:error, status, error_body}})

      {:error, reason} ->
        Logger.error("Anthropic request failed", error: inspect(reason))
        send(caller, {:llm_stop, {:error, reason}})
    end
  end

  # Process parsed SSE events into tagged messages.
  # Returns updated tool accumulator.
  defp dispatch_events(caller, events, tool_acc) do
    Enum.reduce(events, tool_acc, fn event, acc ->
      dispatch_event(caller, event, acc)
    end)
  end

  defp dispatch_event(caller, %{event: "message_start", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"message" => %{"usage" => usage}}} ->
        send(caller, {:llm_usage, normalize_usage(usage)})

      _ ->
        :ok
    end

    tool_acc
  end

  defp dispatch_event(_caller, %{event: "content_block_start", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok,
       %{"index" => idx, "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}}} ->
        Map.put(tool_acc, idx, %{id: id, name: name, input_json: ""})

      _ ->
        tool_acc
    end
  end

  defp dispatch_event(caller, %{event: "content_block_delta", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"delta" => %{"type" => "text_delta", "text" => text}}} ->
        send(caller, {:llm_text, text})
        tool_acc

      {:ok, %{"index" => idx, "delta" => %{"type" => "input_json_delta", "partial_json" => json}}} ->
        case Map.get(tool_acc, idx) do
          %{input_json: existing} = entry ->
            Map.put(tool_acc, idx, %{entry | input_json: existing <> json})

          nil ->
            tool_acc
        end

      _ ->
        tool_acc
    end
  end

  defp dispatch_event(caller, %{event: "content_block_stop", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"index" => idx}} ->
        case Map.pop(tool_acc, idx) do
          {%{id: id, name: name, input_json: json}, new_acc} ->
            input =
              case Jason.decode(json) do
                {:ok, parsed} -> parsed
                _ -> %{}
              end

            send(caller, {:llm_tool_use, %{id: id, name: name, input: input}})
            new_acc

          {nil, _} ->
            tool_acc
        end

      _ ->
        tool_acc
    end
  end

  defp dispatch_event(caller, %{event: "message_delta", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"delta" => delta, "usage" => usage}} ->
        if usage, do: send(caller, {:llm_usage, normalize_usage(usage)})

        if stop_reason = delta["stop_reason"] do
          send(caller, {:llm_stop, stop_reason})
        end

      {:ok, %{"delta" => %{"stop_reason" => stop_reason}}} when not is_nil(stop_reason) ->
        send(caller, {:llm_stop, stop_reason})

      _ ->
        :ok
    end

    tool_acc
  end

  defp dispatch_event(_caller, _event, tool_acc) do
    # Ignore ping, message_stop, and unknown event types
    tool_acc
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_creation_input_tokens: usage["cache_creation_input_tokens"] || 0,
      cache_read_input_tokens: usage["cache_read_input_tokens"] || 0
    }
  end

  defp try_decode_json(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> decoded
      _ -> str
    end
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, ""), do: map
  defp maybe_add(map, _key, []), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp api_key do
    Application.get_env(:cranium, :backends)[:anthropic_api_key] ||
      System.get_env("ANTHROPIC_API_KEY") || ""
  end

  defp model do
    Application.get_env(:cranium, :backends)[:anthropic_model] || @default_model
  end
end

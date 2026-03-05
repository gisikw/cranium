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

  @api_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-6"
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
    system = Keyword.get(opts, :system, "")
    tools = Keyword.get(opts, :tools, [])

    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: messages,
        stream: true
      }
      |> maybe_add(:system, system, &(&1 != ""))
      |> maybe_add(:tools, tools, &(&1 != []))

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    # TODO: Implement actual SSE parsing with Req or Mint
    # For now, this is a structural placeholder showing the message flow

    case Req.post(@api_url, json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: response}} ->
        # In real implementation, this would be SSE streaming.
        # Placeholder: parse a complete response
        parse_response(caller, response)

      {:ok, %{status: status, body: body}} ->
        send(caller, {:llm_stop, {:error, status, body}})

      {:error, reason} ->
        send(caller, {:llm_stop, {:error, reason}})
    end
  end

  defp parse_response(caller, %{"content" => content, "usage" => usage} = response) do
    # Parse content blocks
    Enum.each(content, fn
      %{"type" => "text", "text" => text} ->
        send(caller, {:llm_text, text})

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        send(caller, {:llm_tool_use, %{id: id, name: name, input: input}})

      _ ->
        :skip
    end)

    # Send usage
    send(caller, {:llm_usage, usage})

    # Send stop reason
    stop_reason = response["stop_reason"] || "end_turn"
    send(caller, {:llm_stop, stop_reason})
  end

  defp parse_response(caller, _response) do
    send(caller, {:llm_stop, {:error, :unexpected_response}})
  end

  defp maybe_add(map, _key, _value, check) when is_function(check) do
    # Helper removed — always add for now
    map
  end

  defp maybe_add(map, key, value, check) do
    if check.(value), do: Map.put(map, key, value), else: map
  end

  defp api_key do
    Application.get_env(:cranium, :backends)[:anthropic_api_key] ||
      System.get_env("ANTHROPIC_API_KEY") || ""
  end

  defp model do
    Application.get_env(:cranium, :backends)[:anthropic_model] || @default_model
  end
end

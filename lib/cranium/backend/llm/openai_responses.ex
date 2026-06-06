defmodule Cranium.Backend.LLM.OpenAIResponses do
  @moduledoc """
  OpenAI Responses API backend.

  Supports both metered API key auth (`api.openai.com/v1/responses`) and
  ChatGPT subscription OAuth (`chatgpt.com/backend-api/codex/responses`).

  ## Profile Configuration

      profiles:
        gpt-api:
          backend: openai_responses
          model: gpt-5.5
          backend_config:
            endpoint: https://api.openai.com/v1
            api_key: sk-xxx

        gpt-sub:
          backend: openai_responses
          model: gpt-5.5
          backend_config:
            endpoint: https://chatgpt.com/backend-api/codex
            auth: oauth

  ## Wire Format

  The Responses API uses `instructions` for the system prompt and a flat
  `input` array with typed items (messages, function_call, function_call_output)
  instead of the Chat Completions `messages` array.

  SSE events use named types (like Anthropic) rather than `data:` only chunks.
  """

  @behaviour Cranium.Backend.LLM

  require Logger

  alias Cranium.Backend.SSE
  alias Cranium.Backend.LLM.OpenAIResponses.{Messages, Events}

  @default_max_tokens 8192

  @impl true
  def manages_tool_loop?, do: false

  @impl true
  def stream_chat(messages, opts) do
    caller = self()
    pid = spawn_link(fn -> do_stream(caller, messages, opts) end)
    {:ok, pid}
  end

  defp do_stream(caller, messages, opts) do
    backend_config = Keyword.get(opts, :backend_config, %{})
    endpoint = backend_config["endpoint"] || "https://api.openai.com/v1"
    auth_mode = backend_config["auth"]
    api_key = backend_config["api_key"]

    model = Keyword.get(opts, :model) || "gpt-4o"
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])

    {instructions, input} = Messages.translate(messages, system)

    body =
      %{model: model, input: input, stream: true, store: false}
      |> maybe_add(:instructions, instructions)
      |> maybe_add_unless_oauth(:max_output_tokens, max_tokens, auth_mode)
      |> maybe_add_tools(tools)

    headers = build_headers(auth_mode, api_key)

    Logger.info(
      "OpenAIResponses request: endpoint=#{endpoint} model=#{model} input_items=#{length(input)} tools=#{length(tools)}"
    )

    # Debug: log first tool definition and tool names
    if tools != [] do
      translated = body[:tools] || []
      tool_names = Enum.map(translated, & &1[:name])
      first_tool = List.first(translated)
      Logger.debug("OpenAIResponses tools: names=#{inspect(tool_names)}")
      Logger.debug("OpenAIResponses first_tool: #{inspect(first_tool)}")
    end

    url = String.trim_trailing(endpoint, "/") <> "/responses"

    sse_state = SSE.new()
    tool_acc = %{}

    stream_fn = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        {events, new_sse} = SSE.parse(Process.get(:sse_state, sse_state), data)
        Process.put(:sse_state, new_sse)

        new_tool_acc =
          Events.dispatch_events(caller, events, Process.get(:tool_acc, tool_acc))

        Process.put(:tool_acc, new_tool_acc)

        {:cont, {req, resp}}
      else
        Process.put(:error_body, [data | Process.get(:error_body, [])])
        {:cont, {req, resp}}
      end
    end

    case Req.post(url, json: body, headers: headers, receive_timeout: 300_000, into: stream_fn) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} ->
        error_body =
          Process.get(:error_body, [])
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        Logger.error(
          "OpenAIResponses API error: status=#{status} body=#{String.slice(error_body, 0..500)}"
        )

        send(caller, {:llm_stop, {:error, status, error_body}})

      {:error, reason} ->
        Logger.error("OpenAIResponses request failed", error: inspect(reason))
        send(caller, {:llm_stop, {:error, reason}})
    end
  end

  # --- Auth ---

  defp build_headers("oauth", _api_key) do
    base = [{"content-type", "application/json"}, {"accept", "text/event-stream"}]

    case Cranium.Backend.OAuth.Codex.get_headers() do
      {:ok, oauth_headers} -> oauth_headers ++ base
      {:error, _} -> base
    end
  end

  defp build_headers(_mode, api_key) do
    [{"content-type", "application/json"}, {"accept", "text/event-stream"}]
    |> maybe_add_auth(api_key)
  end

  # --- Helpers ---

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, ""), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  # Codex endpoint rejects max_output_tokens
  defp maybe_add_unless_oauth(map, _key, _value, "oauth"), do: map
  defp maybe_add_unless_oauth(map, key, value, _auth), do: maybe_add(map, key, value)

  defp maybe_add_tools(body, tools) when is_list(tools) and tools != [] do
    Map.put(body, :tools, Messages.translate_tools(tools))
  end

  defp maybe_add_tools(body, _), do: body

  defp maybe_add_auth(headers, nil), do: headers
  defp maybe_add_auth(headers, ""), do: headers
  defp maybe_add_auth(headers, key), do: [{"authorization", "Bearer #{key}"} | headers]
end

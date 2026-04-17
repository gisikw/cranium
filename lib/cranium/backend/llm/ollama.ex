defmodule Cranium.Backend.LLM.Ollama do
  @moduledoc """
  Ollama chat API backend.

  Streams newline-delimited JSON from Ollama's `/api/chat` endpoint and
  translates into the tagged message protocol defined by `Backend.LLM`.

  Model-specific parameters (temperature, context window, sampling) live
  in Ollama Modelfiles — cranium passes model name and messages only.
  """

  @behaviour Cranium.Backend.LLM

  require Logger

  @default_model "gemma4"

  @impl true
  def manages_tool_loop?, do: false

  @impl true
  def stream_chat(messages, opts) do
    caller = self()
    pid = spawn_link(fn -> do_stream(caller, messages, opts) end)
    {:ok, pid}
  end

  defp do_stream(caller, messages, opts) do
    url = Cranium.Config.ollama_url()
    model = Keyword.get(opts, :model) || @default_model
    system = Keyword.get(opts, :system)
    max_tokens = Keyword.get(opts, :max_tokens)
    thinking = Keyword.get(opts, :thinking)
    tools = Keyword.get(opts, :tools, [])

    ollama_messages = build_messages(system, messages)

    body =
      %{model: model, messages: ollama_messages, stream: true}
      |> maybe_add_options(max_tokens)
      |> maybe_add_thinking(thinking)
      |> maybe_add_tools(tools)

    Logger.info("Ollama request: model=#{model} messages=#{length(ollama_messages)} tools=#{length(tools)} think=#{thinking}")

    stream_fn = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        buffer = Process.get(:ndjson_buffer, "")
        {lines, rest} = split_lines(buffer <> data)
        Process.put(:ndjson_buffer, rest)
        Enum.each(lines, &dispatch_line(caller, &1))
        {:cont, {req, resp}}
      else
        Process.put(:error_body, [data | Process.get(:error_body, [])])
        {:cont, {req, resp}}
      end
    end

    case Req.post("#{url}/api/chat",
           json: body,
           receive_timeout: 300_000,
           into: stream_fn
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} ->
        error_body =
          Process.get(:error_body, [])
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        Logger.error("Ollama API error: status=#{status} body=#{String.slice(error_body, 0..500)}")
        send(caller, {:llm_stop, {:error, status, error_body}})

      {:error, reason} ->
        Logger.error("Ollama request failed", error: inspect(reason))
        send(caller, {:llm_stop, {:error, reason}})
    end
  end

  defp dispatch_line(caller, line) do
    case Jason.decode(line) do
      {:ok, chunk} ->
        dispatch_chunk(caller, chunk)

      {:error, _} ->
        Logger.warning("Ollama: failed to parse NDJSON line", line: String.slice(line, 0..100))
    end
  end

  # Ollama may stream tool_calls in either a `done: false` or `done: true`
  # chunk depending on model and timing; text content may arrive alongside.
  # Extract each field wherever it appears, independent of `done`.
  defp dispatch_chunk(caller, chunk) do
    message = chunk["message"] || %{}

    case message["content"] do
      text when is_binary(text) and text != "" -> send(caller, {:llm_text, text})
      _ -> :ok
    end

    case message["tool_calls"] do
      calls when is_list(calls) and calls != [] ->
        Enum.each(calls, &dispatch_tool_call(caller, &1))
        Process.put(:emitted_tool_calls, true)

      _ ->
        :ok
    end

    if chunk["done"] == true, do: dispatch_done(caller, chunk)
  end

  defp dispatch_tool_call(caller, tc) do
    func = tc["function"] || %{}

    send(caller, {:llm_tool_use, %{
      id: generate_tool_id(),
      name: func["name"],
      input: func["arguments"] || %{}
    }})
  end

  defp dispatch_done(caller, chunk) do
    emitted_tools = Process.get(:emitted_tool_calls, false)
    Process.delete(:emitted_tool_calls)

    if emitted_tools do
      send(caller, {:llm_stop, "tool_use"})
    else
      usage = %{
        input_tokens: chunk["prompt_eval_count"] || 0,
        output_tokens: chunk["eval_count"] || 0
      }

      send(caller, {:llm_usage, usage})
      send(caller, {:llm_stop, "end_turn"})
    end
  end

  # --- Message building ---

  defp build_messages(nil, messages), do: normalize_messages(messages)
  defp build_messages("", messages), do: normalize_messages(messages)

  defp build_messages(system, messages) do
    [%{role: "system", content: system} | normalize_messages(messages)]
  end

  # Translate Anthropic-shaped messages into Ollama's chat protocol.
  # Assistant messages with tool_use blocks become `role: "assistant"` with
  # a `tool_calls` array. User messages carrying only tool_result blocks
  # become one or more `role: "tool"` messages. Everything else flattens
  # to plain string content.
  defp normalize_messages(messages) do
    Enum.flat_map(messages, &normalize_message/1)
  end

  defp normalize_message(msg) do
    role = to_string(msg[:role] || msg["role"])
    content = msg[:content] || msg["content"]

    case {role, content} do
      {_, text} when is_binary(text) ->
        [%{role: role, content: text}]

      {"assistant", blocks} when is_list(blocks) ->
        text = flatten_content_blocks(blocks)
        tool_calls = extract_tool_uses(blocks)

        base = %{role: "assistant", content: text}
        if tool_calls == [], do: [base], else: [Map.put(base, :tool_calls, tool_calls)]

      {"user", blocks} when is_list(blocks) ->
        {tool_results, other} = split_tool_results(blocks)

        tool_msgs = Enum.map(tool_results, &to_tool_message/1)

        case flatten_content_blocks(other) do
          "" -> tool_msgs
          text -> tool_msgs ++ [%{role: "user", content: text}]
        end

      _ ->
        [%{role: role, content: ""}]
    end
  end

  defp flatten_content_blocks(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      %{type: "text", text: t} -> t
      %{"type" => "text", "text" => t} -> t
      _ -> ""
    end)
  end

  defp extract_tool_uses(blocks) do
    Enum.flat_map(blocks, fn
      %{type: "tool_use", name: name, input: input} ->
        [%{type: "function", function: %{name: name, arguments: input}}]

      %{"type" => "tool_use", "name" => name, "input" => input} ->
        [%{type: "function", function: %{name: name, arguments: input}}]

      _ ->
        []
    end)
  end

  defp split_tool_results(blocks) do
    Enum.split_with(blocks, fn
      %{type: "tool_result"} -> true
      %{"type" => "tool_result"} -> true
      _ -> false
    end)
  end

  defp to_tool_message(%{type: "tool_result", content: content}),
    do: %{role: "tool", content: stringify_tool_content(content)}

  defp to_tool_message(%{"type" => "tool_result", "content" => content}),
    do: %{role: "tool", content: stringify_tool_content(content)}

  defp stringify_tool_content(content) when is_binary(content), do: content

  defp stringify_tool_content(content) when is_list(content),
    do: flatten_content_blocks(content)

  defp stringify_tool_content(other), do: inspect(other)

  # --- Helpers ---

  defp maybe_add_options(body, nil), do: body

  defp maybe_add_options(body, max_tokens) do
    Map.put(body, :options, %{num_predict: max_tokens})
  end

  defp maybe_add_thinking(body, true), do: Map.put(body, :think, true)
  defp maybe_add_thinking(body, false), do: Map.put(body, :think, false)
  defp maybe_add_thinking(body, _nil), do: body

  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, nil), do: body

  defp maybe_add_tools(body, tools) when is_list(tools) do
    Map.put(body, :tools, Enum.map(tools, &to_ollama_tool/1))
  end

  defp to_ollama_tool(%{name: name, description: description, input_schema: schema}) do
    %{
      type: "function",
      function: %{name: name, description: description, parameters: schema}
    }
  end

  defp to_ollama_tool(%{"name" => name, "description" => description, "input_schema" => schema}) do
    %{
      type: "function",
      function: %{name: name, description: description, parameters: schema}
    }
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [single] -> {[], single}
      parts ->
        {lines, [rest]} = Enum.split(parts, -1)
        {Enum.reject(lines, &(&1 == "")), rest}
    end
  end

  defp generate_tool_id do
    "toolu_" <> (Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))
  end
end

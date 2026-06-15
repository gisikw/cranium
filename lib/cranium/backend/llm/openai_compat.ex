defmodule Cranium.Backend.LLM.OpenAICompat do
  @moduledoc """
  OpenAI-compatible chat completions backend.

  Supports any server exposing the OpenAI `/v1/chat/completions` SSE
  streaming endpoint — llama.cpp, vLLM, text-generation-inference, etc.

  ## Profile Configuration

      profiles:
        qwen-local:
          backend: openai_compat
          model: qwen3.6-27b
          thinking: false
          backend_config:
            endpoint: https://llama.gisi.network/v1
            api_key: sk-xxx
            thinking_mode: prefill   # optional, for models like Qwen3.6

  ## Thinking Modes

  - `nil` / absent — pass `thinking` as a body parameter (API ignores if unsupported)
  - `"prefill"` — Qwen3.6 style: prepend `</think>` assistant message to disable thinking
  """

  @behaviour Cranium.Backend.LLM

  require Logger

  alias Cranium.Backend.SSE

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
    endpoint = backend_config["endpoint"] || "http://localhost:8080/v1"
    api_key = backend_config["api_key"]
    thinking_mode = backend_config["thinking_mode"]

    model = Keyword.get(opts, :model) || "default"
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])
    thinking = Keyword.get(opts, :thinking)

    oai_messages = build_messages(system, messages, thinking, thinking_mode)

    body =
      %{model: model, messages: oai_messages, max_tokens: max_tokens, stream: true}
      |> maybe_add_thinking(thinking, thinking_mode)
      |> maybe_add_tools(tools)
      |> maybe_add_stream_options()

    Logger.info(
      "OpenAICompat request: endpoint=#{endpoint} model=#{model} messages=#{length(oai_messages)} tools=#{length(tools)} thinking=#{thinking}"
    )

    headers =
      [{"content-type", "application/json"}, {"accept", "text/event-stream"}]
      |> maybe_add_auth(api_key)

    sse_state = SSE.new()
    tool_acc = %{}

    stream_fn = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        {events, sse_state} = SSE.parse(Process.get(:sse_state, sse_state), data)
        Process.put(:sse_state, sse_state)

        tool_acc = Process.get(:tool_acc, tool_acc)
        tool_acc = Enum.reduce(events, tool_acc, &dispatch_event(caller, &1, &2))
        Process.put(:tool_acc, tool_acc)

        {:cont, {req, resp}}
      else
        Process.put(:error_body, [data | Process.get(:error_body, [])])
        {:cont, {req, resp}}
      end
    end

    url = String.trim_trailing(endpoint, "/") <> "/chat/completions"

    case Req.post(url, json: body, headers: headers, receive_timeout: 300_000, into: stream_fn) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} ->
        error_body =
          Process.get(:error_body, [])
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        Logger.error(
          "OpenAICompat API error: status=#{status} body=#{String.slice(error_body, 0..500)}"
        )

        send(caller, {:llm_stop, {:error, status, error_body}})

      {:error, reason} ->
        Logger.error("OpenAICompat request failed", error: inspect(reason))
        send(caller, {:llm_stop, {:error, reason}})
    end
  end

  # --- SSE Event Dispatch ---

  # OpenAI SSE format:
  #   data: {"choices":[{"delta":{"content":"Hi"},"index":0}]}
  #   data: {"choices":[{"delta":{"tool_calls":[{...}]},"index":0}]}
  #   data: {"choices":[{"finish_reason":"stop","index":0}],"usage":{...}}
  #   data: [DONE]

  defp dispatch_event(_caller, %{data: "[DONE]"}, tool_acc), do: tool_acc

  defp dispatch_event(caller, %{data: json_str}, tool_acc) do
    case Jason.decode(json_str) do
      {:ok, data} ->
        handle_chunk(caller, data, tool_acc)

      {:error, _} ->
        Logger.warning("OpenAICompat: failed to parse SSE data",
          data: String.slice(json_str, 0..100)
        )

        tool_acc
    end
  end

  defp handle_chunk(caller, %{"choices" => choices} = data, tool_acc) do
    tool_acc =
      Enum.reduce(choices, tool_acc, fn choice, acc ->
        delta = choice["delta"] || %{}

        # Text content
        case delta["content"] do
          text when is_binary(text) and text != "" -> send(caller, {:llm_text, text})
          _ -> :ok
        end

        # Tool calls (streamed incrementally by index)
        acc = handle_tool_calls(caller, delta["tool_calls"], acc)

        # Finish reason
        case choice["finish_reason"] do
          "stop" ->
            send(caller, {:llm_stop, "end_turn"})

          "tool_calls" ->
            flush_pending_tools(caller, acc)
            send(caller, {:llm_stop, "tool_use"})

          "length" ->
            send(caller, {:llm_stop, "end_turn"})

          _ ->
            :ok
        end

        acc
      end)

    # Usage (may appear in final chunk or separate)
    case data["usage"] do
      %{"prompt_tokens" => input, "completion_tokens" => output} ->
        send(caller, {:llm_usage, %{input_tokens: input, output_tokens: output}})

      _ ->
        :ok
    end

    tool_acc
  end

  defp handle_chunk(_caller, _data, tool_acc), do: tool_acc

  # OpenAI streams tool calls incrementally: each delta has an index,
  # first chunk has id + function.name, subsequent chunks append to
  # function.arguments.
  defp handle_tool_calls(_caller, nil, acc), do: acc
  defp handle_tool_calls(_caller, [], acc), do: acc

  defp handle_tool_calls(caller, tool_calls, acc) do
    Enum.reduce(tool_calls, acc, fn tc, acc ->
      index = tc["index"] || 0
      func = tc["function"] || %{}

      existing = Map.get(acc, index, %{id: nil, name: nil, arguments: ""})

      updated = %{
        id: tc["id"] || existing.id || generate_tool_id(),
        name: func["name"] || existing.name,
        arguments: existing.arguments <> (func["arguments"] || "")
      }

      # If we have a complete tool call (got an id and name), keep accumulating
      # arguments until finish_reason signals completion
      Map.put(acc, index, updated)
    end)
  end

  defp flush_pending_tools(caller, tool_acc) do
    tool_acc
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.each(fn {_index, tc} ->
      input =
        case Jason.decode(tc.arguments) do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end

      send(caller, {:llm_tool_use, %{id: tc.id, name: tc.name, input: input}})
    end)
  end

  # --- Message Building ---

  defp build_messages(system, messages, thinking, thinking_mode) do
    msgs = normalize_messages(messages)

    msgs =
      case system do
        s when is_binary(s) and s != "" -> [%{role: "system", content: s} | msgs]
        _ -> msgs
      end

    # Qwen3.6 prefill: add </think> assistant message to disable thinking
    if thinking_mode == "prefill" and thinking == false do
      msgs ++ [%{role: "assistant", content: "</think>", prefix: true}]
    else
      msgs
    end
  end

  # Reuse Ollama-style normalization: Anthropic content blocks → OpenAI format
  defp normalize_messages(messages), do: Enum.flat_map(messages, &normalize_message/1)

  defp normalize_message(msg) do
    role = to_string(msg[:role] || msg["role"])
    content = msg[:content] || msg["content"]

    case {role, content} do
      {_, text} when is_binary(text) ->
        [%{role: role, content: text}]

      {"assistant", blocks} when is_list(blocks) ->
        text = flatten_text(blocks)
        tool_calls = extract_tool_calls(blocks)
        base = %{role: "assistant", content: text}
        if tool_calls == [], do: [base], else: [Map.put(base, :tool_calls, tool_calls)]

      {"user", blocks} when is_list(blocks) ->
        {tool_results, other} = split_tool_results(blocks)
        tool_msgs = Enum.map(tool_results, &to_tool_message/1)

        content_parts = openai_content_parts(other)

        case content_parts do
          [] -> tool_msgs
          parts -> tool_msgs ++ [%{role: "user", content: parts}]
        end

      _ ->
        [%{role: role, content: ""}]
    end
  end

  defp flatten_text(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      %{type: "text", text: t} -> t
      %{"type" => "text", "text" => t} -> t
      _ -> ""
    end)
  end

  defp openai_content_parts(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{text: t} when is_binary(t) ->
        [%{"type" => "text", "text" => t}]

      %{"text" => t} when is_binary(t) ->
        [%{"type" => "text", "text" => t}]

      %{type: "text", text: t} when is_binary(t) ->
        [%{"type" => "text", "text" => t}]

      %{"type" => "text", "text" => t} when is_binary(t) ->
        [%{"type" => "text", "text" => t}]

      %{"type" => "image"} = block ->
        case Cranium.ImageInput.internal_image_to_openai_chat_part(block) do
          nil -> []
          part -> [part]
        end

      %{type: "image"} = block ->
        case Cranium.ImageInput.internal_image_to_openai_chat_part(block) do
          nil -> []
          part -> [part]
        end

      _ ->
        []
    end)
  end

  defp extract_tool_calls(blocks) do
    Enum.flat_map(blocks, fn
      %{type: "tool_use", id: id, name: name, input: input} ->
        [%{id: id, type: "function", function: %{name: name, arguments: Jason.encode!(input)}}]

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        [%{id: id, type: "function", function: %{name: name, arguments: Jason.encode!(input)}}]

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

  defp to_tool_message(%{tool_use_id: id, content: content}),
    do: %{role: "tool", tool_call_id: id, content: stringify(content)}

  defp to_tool_message(%{"tool_use_id" => id, "content" => content}),
    do: %{role: "tool", tool_call_id: id, content: stringify(content)}

  defp to_tool_message(%{type: "tool_result", tool_use_id: id, content: content}),
    do: %{role: "tool", tool_call_id: id, content: stringify(content)}

  defp to_tool_message(%{"type" => "tool_result", "tool_use_id" => id, "content" => content}),
    do: %{role: "tool", tool_call_id: id, content: stringify(content)}

  defp stringify(content) when is_binary(content), do: content
  defp stringify(content) when is_list(content), do: flatten_text(content)
  defp stringify(other), do: inspect(other)

  # --- Helpers ---

  defp maybe_add_thinking(body, thinking, thinking_mode) when thinking_mode != "prefill" do
    case thinking do
      true -> Map.put(body, :thinking, true)
      false -> Map.put(body, :thinking, false)
      _ -> body
    end
  end

  defp maybe_add_thinking(body, _thinking, _thinking_mode), do: body

  defp maybe_add_tools(body, tools) when is_list(tools) and tools != [] do
    oai_tools =
      Enum.map(tools, fn tool ->
        name = tool[:name] || tool["name"]
        desc = tool[:description] || tool["description"]
        schema = tool[:input_schema] || tool["input_schema"]
        %{type: "function", function: %{name: name, description: desc, parameters: schema}}
      end)

    Map.put(body, :tools, oai_tools)
  end

  defp maybe_add_tools(body, _), do: body

  defp maybe_add_stream_options(body) do
    Map.put(body, :stream_options, %{include_usage: true})
  end

  defp maybe_add_auth(headers, nil), do: headers
  defp maybe_add_auth(headers, ""), do: headers
  defp maybe_add_auth(headers, key), do: [{"authorization", "Bearer #{key}"} | headers]

  defp generate_tool_id do
    "toolu_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end
end

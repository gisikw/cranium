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

  @default_model "gemma4-cranium"

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

    ollama_messages = build_messages(system, messages)

    body =
      %{model: model, messages: ollama_messages, stream: true}
      |> maybe_add_options(max_tokens)

    Logger.info("Ollama request: model=#{model} messages=#{length(ollama_messages)}")

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

        Logger.error("Ollama API error", status: status, body: error_body)
        send(caller, {:llm_stop, {:error, status, error_body}})

      {:error, reason} ->
        Logger.error("Ollama request failed", error: inspect(reason))
        send(caller, {:llm_stop, {:error, reason}})
    end
  end

  defp dispatch_line(caller, line) do
    case Jason.decode(line) do
      {:ok, %{"done" => false, "message" => %{"content" => text}}} when text != "" ->
        send(caller, {:llm_text, text})

      {:ok, %{"done" => true, "message" => %{"tool_calls" => tool_calls}}}
      when is_list(tool_calls) and tool_calls != [] ->
        Enum.each(tool_calls, fn tc ->
          func = tc["function"] || %{}

          send(caller, {:llm_tool_use, %{
            id: generate_tool_id(),
            name: func["name"],
            input: func["arguments"] || %{}
          }})
        end)

        send(caller, {:llm_stop, "tool_use"})

      {:ok, %{"done" => true} = final} ->
        usage = %{
          input_tokens: final["prompt_eval_count"] || 0,
          output_tokens: final["eval_count"] || 0
        }

        send(caller, {:llm_usage, usage})
        send(caller, {:llm_stop, "end_turn"})

      {:ok, %{"done" => false}} ->
        # Empty content chunk, ignore
        :ok

      {:error, _} ->
        Logger.warning("Ollama: failed to parse NDJSON line", line: String.slice(line, 0..100))

      _ ->
        :ok
    end
  end

  # --- Message building ---

  defp build_messages(nil, messages), do: normalize_messages(messages)
  defp build_messages("", messages), do: normalize_messages(messages)

  defp build_messages(system, messages) do
    [%{role: "system", content: system} | normalize_messages(messages)]
  end

  # Normalize from Anthropic-style content blocks to Ollama's plain string format
  defp normalize_messages(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]

      text =
        case content do
          s when is_binary(s) -> s
          blocks when is_list(blocks) -> flatten_content_blocks(blocks)
          _ -> ""
        end

      %{role: to_string(role), content: text}
    end)
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

  # --- Helpers ---

  defp maybe_add_options(body, nil), do: body

  defp maybe_add_options(body, max_tokens) do
    Map.put(body, :options, %{num_predict: max_tokens})
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

defmodule Cranium.Transport.OpenAI do
  @moduledoc """
  OpenAI-compatible API handler.

  Provides `POST /v1/chat/completions` and `GET /v1/models` in the OpenAI
  wire format. Routes are declared in `Transport.HTTP`; this module owns
  the handler logic.

  ## Design

  This is a thin translation proxy. It resolves a cranium profile from the
  request's `model` field, applies the profile's system prompt policy,
  dispatches directly to the LLM backend's `stream_chat/2`, and translates
  tagged messages back into the OpenAI response format.

  No epochs, no history persistence, no landscape injection, no turn
  injection. All requests are ephemeral.

  ## System Prompt Policy

  Each profile has an `openai_system_mode` setting:

  - `:replace` — profile identity replaces any client system messages
  - `:prepend` — profile identity before client system
  - `:append` — client system before profile identity
  """

  require Logger

  @doc "Handle POST /v1/chat/completions."
  @spec chat_completions(Plug.Conn.t()) :: Plug.Conn.t()
  def chat_completions(conn) do
    model_name = conn.body_params["model"]
    stream = conn.body_params["stream"] == true
    messages = conn.body_params["messages"] || []
    max_tokens = conn.body_params["max_tokens"]

    case resolve(model_name, messages) do
      {:ok, profile, system, backend_messages} ->
        completion_id = "cranium-" <> Cranium.Stage.new_stream_id()

        opts = [
          system: system,
          model: profile.model,
          max_tokens: max_tokens || 8192,
          tools: [],
          ephemeral: true,
          working_dir: ephemeral_working_dir()
        ]

        Logger.info("OpenAI: model=#{model_name} stream=#{stream} messages=#{length(backend_messages)}")

        if stream do
          stream_response(conn, backend_messages, opts, profile, completion_id)
        else
          buffered_response(conn, backend_messages, opts, profile, completion_id)
        end

      {:error, :profile_not_found} ->
        error_response(conn, 404, "model '#{model_name}' not found")

      {:error, reason} ->
        error_response(conn, 500, "internal error: #{inspect(reason)}")
    end
  end

  @doc "Handle GET /v1/models."
  @spec models(Plug.Conn.t()) :: Plug.Conn.t()
  def models(conn) do
    now = System.os_time(:second)

    data =
      Cranium.Config.list_profiles()
      |> Enum.map(fn name ->
        %{"id" => name, "object" => "model", "created" => now, "owned_by" => "cranium"}
      end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"object" => "list", "data" => data}))
  end

  # --- Resolution ---

  defp resolve(nil, _messages), do: {:error, :profile_not_found}

  defp resolve(model_name, messages) do
    case Cranium.Config.resolve_profile(model_name) do
      {:ok, resolved} ->
        {client_system, non_system} = extract_system_messages(messages)
        system = apply_system_mode(resolved.openai_system_mode, resolved.identity, client_system)
        {:ok, resolved, system, non_system}

      {:error, :not_found} ->
        {:error, :profile_not_found}
    end
  end

  # --- System Prompt Assembly ---

  defp extract_system_messages(messages) do
    {system_msgs, other_msgs} =
      Enum.split_with(messages, fn msg ->
        (msg["role"] || msg[:role]) == "system"
      end)

    client_system =
      system_msgs
      |> Enum.map(fn msg -> msg["content"] || msg[:content] || "" end)
      |> Enum.join("\n\n")

    {client_system, other_msgs}
  end

  defp apply_system_mode(:replace, identity, _client) when is_binary(identity), do: identity
  defp apply_system_mode(:replace, nil, client), do: client

  defp apply_system_mode(:prepend, identity, client) do
    join_system(identity, client)
  end

  defp apply_system_mode(:append, identity, client) do
    join_system(client, identity)
  end

  defp join_system(nil, b), do: b || ""
  defp join_system(a, nil), do: a || ""
  defp join_system("", b), do: b
  defp join_system(a, ""), do: a
  defp join_system(a, b), do: a <> "\n\n" <> b

  # --- Streaming Response ---

  defp stream_response(conn, messages, opts, profile, completion_id) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)

    # Send initial role chunk
    {:ok, conn} = send_sse_chunk(conn, completion_id, profile.name, %{"role" => "assistant"}, nil)

    case profile.backend_module.stream_chat(messages, opts) do
      {:ok, llm_pid} ->
        ref = Process.monitor(llm_pid)
        {conn, usage} = stream_receive_loop(conn, llm_pid, ref, completion_id, profile.name)

        # Send final chunk with finish_reason and usage
        {:ok, conn} = send_sse_chunk(conn, completion_id, profile.name, %{}, "stop", usage)
        {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
        conn

      {:error, reason} ->
        Logger.error("OpenAI: backend stream_chat failed", error: inspect(reason))
        # Already sent 200 chunked — best we can do is close
        conn
    end
  end

  defp stream_receive_loop(conn, llm_pid, ref, completion_id, model_name) do
    receive do
      {:llm_text, text} ->
        case send_sse_chunk(conn, completion_id, model_name, %{"content" => text}, nil) do
          {:ok, conn} ->
            stream_receive_loop(conn, llm_pid, ref, completion_id, model_name)

          {:error, _} ->
            # Client disconnected
            Process.demonitor(ref, [:flush])
            Process.exit(llm_pid, :shutdown)
            {conn, nil}
        end

      {:llm_tool_use, _tool_call} ->
        # Swallow tool calls — not exposed to OpenAI clients
        stream_receive_loop(conn, llm_pid, ref, completion_id, model_name)

      {:llm_usage, usage} ->
        # Stash usage for final chunk
        Process.put(:openai_usage, usage)
        stream_receive_loop(conn, llm_pid, ref, completion_id, model_name)

      {:llm_stop, "end_turn"} ->
        Process.demonitor(ref, [:flush])
        await_exit(llm_pid)
        {conn, Process.get(:openai_usage)}

      {:llm_stop, "tool_use"} ->
        # Backend wants tool execution but we don't support it — treat as end
        Process.demonitor(ref, [:flush])
        await_exit(llm_pid)
        {conn, Process.get(:openai_usage)}

      {:llm_stop, {:error, _} = _err} ->
        Process.demonitor(ref, [:flush])
        {conn, Process.get(:openai_usage)}

      {:cc_session, _session_id} ->
        stream_receive_loop(conn, llm_pid, ref, completion_id, model_name)

      {:cc_tool_use, _} ->
        stream_receive_loop(conn, llm_pid, ref, completion_id, model_name)

      {:cc_tool_result, _} ->
        stream_receive_loop(conn, llm_pid, ref, completion_id, model_name)

      {:DOWN, ^ref, :process, ^llm_pid, :normal} ->
        {conn, Process.get(:openai_usage)}

      {:DOWN, ^ref, :process, ^llm_pid, reason} ->
        Logger.error("OpenAI: LLM process crashed", reason: inspect(reason))
        {conn, Process.get(:openai_usage)}
    after
      300_000 ->
        Process.demonitor(ref, [:flush])
        Process.exit(llm_pid, :shutdown)
        {conn, Process.get(:openai_usage)}
    end
  end

  # --- Buffered (Non-Streaming) Response ---

  defp buffered_response(conn, messages, opts, profile, completion_id) do
    case profile.backend_module.stream_chat(messages, opts) do
      {:ok, llm_pid} ->
        ref = Process.monitor(llm_pid)
        {text, usage} = buffered_receive_loop(llm_pid, ref, [], nil)

        body = %{
          "id" => completion_id,
          "object" => "chat.completion",
          "created" => System.os_time(:second),
          "model" => profile.name,
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => text},
              "finish_reason" => "stop"
            }
          ],
          "usage" => format_usage(usage)
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))

      {:error, reason} ->
        error_response(conn, 502, "backend error: #{inspect(reason)}")
    end
  end

  defp buffered_receive_loop(llm_pid, ref, acc, usage) do
    receive do
      {:llm_text, text} ->
        buffered_receive_loop(llm_pid, ref, [text | acc], usage)

      {:llm_tool_use, _} ->
        buffered_receive_loop(llm_pid, ref, acc, usage)

      {:llm_usage, new_usage} ->
        buffered_receive_loop(llm_pid, ref, acc, new_usage)

      {:llm_stop, "end_turn"} ->
        Process.demonitor(ref, [:flush])
        await_exit(llm_pid)
        {acc |> Enum.reverse() |> Enum.join(), usage}

      {:llm_stop, "tool_use"} ->
        Process.demonitor(ref, [:flush])
        await_exit(llm_pid)
        {acc |> Enum.reverse() |> Enum.join(), usage}

      {:llm_stop, {:error, _}} ->
        Process.demonitor(ref, [:flush])
        {acc |> Enum.reverse() |> Enum.join(), usage}

      {:cc_session, _} ->
        buffered_receive_loop(llm_pid, ref, acc, usage)

      {:cc_tool_use, _} ->
        buffered_receive_loop(llm_pid, ref, acc, usage)

      {:cc_tool_result, _} ->
        buffered_receive_loop(llm_pid, ref, acc, usage)

      {:DOWN, ^ref, :process, ^llm_pid, :normal} ->
        {acc |> Enum.reverse() |> Enum.join(), usage}

      {:DOWN, ^ref, :process, ^llm_pid, reason} ->
        Logger.error("OpenAI: LLM process crashed in buffered mode", reason: inspect(reason))
        {acc |> Enum.reverse() |> Enum.join(), usage}
    after
      300_000 ->
        Process.demonitor(ref, [:flush])
        Process.exit(llm_pid, :shutdown)
        {acc |> Enum.reverse() |> Enum.join(), usage}
    end
  end

  # --- SSE Formatting ---

  defp send_sse_chunk(conn, id, model, delta, finish_reason, usage \\ nil) do
    chunk = %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => System.os_time(:second),
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "delta" => delta,
          "finish_reason" => finish_reason
        }
      ]
    }

    chunk = if usage, do: Map.put(chunk, "usage", format_usage(usage)), else: chunk

    Plug.Conn.chunk(conn, "data: #{Jason.encode!(chunk)}\n\n")
  end

  defp format_usage(nil) do
    %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
  end

  defp format_usage(usage) do
    input = usage[:input_tokens] || usage["input_tokens"] || 0
    output = usage[:output_tokens] || usage["output_tokens"] || 0

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output
    }
  end

  # --- Helpers ---

  defp error_response(conn, status, message) do
    body = %{
      "error" => %{
        "message" => message,
        "type" => "invalid_request_error",
        "code" => nil
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp ephemeral_working_dir do
    dir = Path.join(System.tmp_dir!(), "cranium/openai")
    File.mkdir_p!(dir)
    dir
  end

  defp await_exit(pid) do
    if Process.alive?(pid) do
      receive do
        {:DOWN, _, :process, ^pid, _} -> :ok
      after
        3_000 -> :ok
      end
    end
  end
end

defmodule Cranium.Inference.Agent do
  @moduledoc """
  Inference and tool management stage.

  This is the most complex pipeline stage — a lightweight agent harness that
  manages the LLM inference loop. Unlike other stages, Agent processes are
  per-epoch (spawned by the Epoch coordinator), not singleton.

  Decomposes into four steps:

  - `Harness` — core loop: send context → stream response → detect tool
    calls → execute → continue generating
  - `ToolRouter` — map tool names to executors, distinguish real tools
    from SCTE markers
  - `ToolExecutor` — run real tool calls, return results
  - `MarkerEmitter` — intercept marker tools, return fake success, emit
    positional markers into the output stream

  ## Inference Loop

      1. Send assembled context to LLM backend (streaming)
      2. Receive response chunks via SSE
      3. Forward text chunks to Egress (streaming)
      4. If response contains tool_use:
         a. Check ToolRouter — real tool or marker?
         b. Marker: emit marker to output stream, fake success to model
         c. Real tool: execute via ToolExecutor, get result
         d. Append tool_result to messages, go to step 1
      5. If response is complete (stop_reason: "end_turn"):
         a. Signal stream end to Egress
         b. Return final state to Epoch

  ## Cancel

  On cancel, the Agent process exits immediately. The LLM backend connection
  is closed. Any in-flight chunks already forwarded to Egress drain naturally.
  The Epoch captures partial output for the interrupted context breadcrumb.

  ## Streaming

  Agent is the primary streaming producer. It receives SSE chunks from the
  LLM backend and forwards them to Egress. The streaming interface here is
  producer-side: Agent sends `{:chunk, stream_id, data}` messages to the
  Egress process.
  """

  use GenServer

  require Logger

  use TypedStruct

  typedstruct do
    field :conversation_id, String.t()
    field :epoch_pid, pid() | nil
    field :stream_id, String.t() | nil
    field :llm_backend, module()
    field :cc_session_id, String.t() | nil
    field :status, :idle | :inferring | :tool_use | :cancelled, default: :idle
    field :messages, list(), default: []
    field :tool_calls_pending, list(), default: []
    field :partial_output, list(), default: []
    field :usage, map(), default: %{input_tokens: 0, output_tokens: 0}
    # For CC path: tracks pending clear_context call (nil or continuation string)
    field :pending_clear, String.t() | nil, default: nil
  end

  # --- Public API ---

  @doc """
  Start an Agent process for an epoch.

  The agent is linked to the calling epoch — if the epoch dies, the
  agent dies too.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Begin inference with the assembled context.

  Streams output via `Cranium.Events` on three topics:
  - `{:stream_raw, stream_id}` — per-stream subscribers
  - `{:conversation, conversation_id}` — conversation-level firehose
  - `:global` — global firehose (all conversations)

  Returns when inference is complete (including any tool call loops).
  """
  @spec infer(pid(), map()) :: {:ok, map()} | {:error, :cancelled, map()} | {:error, term()}
  def infer(pid, context) do
    GenServer.call(pid, {:infer, context}, :infinity)
  end

  # --- GenServer Implementation ---

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    llm_backend = Keyword.get(opts, :llm_backend) || backend_module()

    Logger.metadata(conversation_id: conversation_id, stage: :agent)
    Logger.info("Agent started", backend: inspect(llm_backend))

    state = %__MODULE__{
      conversation_id: conversation_id,
      epoch_pid: Keyword.get(opts, :epoch_pid),
      llm_backend: llm_backend
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:infer, context}, _from, state) do
    stream_id = context[:stream_id] || Cranium.Stage.new_stream_id()

    # Silent flag suppresses raw stream events from the firehose (see emit/3).
    if context[:silent], do: Process.put(:emit_silent, true)

    messages = context[:messages] || []
    system = context[:system]

    state = %{
      state
      | status: :inferring,
        stream_id: stream_id,
        messages: messages,
        partial_output: [],
        usage: %{input_tokens: 0, output_tokens: 0}
    }

    # Signal stream start to all subscribers
    metadata = %{
      conversation_id: state.conversation_id,
      content_type: :llm_response,
      mode: Map.get(context, :mode, :text),
      disposition: Map.get(context, :disposition, ["text"]),
      dispatch: context[:dispatch],
      source: :agent
    }

    emit(stream_id, state.conversation_id, {:stream_start, stream_id, metadata})

    # Start the LLM backend stream — skip tool definitions for managed-loop backends
    # or when tools are explicitly disabled (e.g. orientation passes).
    # For CC backend, tools: "" disables all tools including MCP; for API/Ollama,
    # an empty list omits tool definitions from the request.
    tools_disabled = context[:tools_disabled] == true

    tools =
      cond do
        tools_disabled and state.llm_backend.manages_tool_loop?() -> ""
        tools_disabled -> []
        state.llm_backend.manages_tool_loop?() -> []
        true -> Cranium.Inference.Agent.ToolRouter.tool_definitions(state.conversation_id)
      end

    disposition = Map.get(context, :disposition, ["text"])

    opts = [
      system: system,
      max_tokens: Map.get(context, :max_tokens, 8192),
      tools: tools,
      cc_session_id: context[:cc_session_id],
      working_dir: context[:working_dir],
      model: context[:model],
      thinking: context[:thinking],
      backend_config: context[:backend_config],
      ephemeral: context[:ephemeral],
      effort_level: if("audio" in disposition, do: "low"),
      tool_posture: context[:tool_posture] || :sandbox,
      tool_rw: context[:tool_rw] || [],
      tool_ro: context[:tool_ro] || []
    ]

    result = run_inference(state, stream_id, messages, opts)

    # If inference succeeded but produced no output (e.g. model safety refusal
    # returning empty string), emit a visible message so the client isn't left
    # staring at nothing.
    result =
      case result do
        {:ok, :cleared} ->
          # clear_context path already emitted stream_end, skip post-processing
          {:ok, :cleared}

        {:ok, final_state} when final_state.partial_output == [] ->
          Logger.warning("Model returned empty response, emitting placeholder",
            conversation_id: state.conversation_id)

          placeholder = "[Model returned empty response]"
          emit(stream_id, state.conversation_id, {:chunk, stream_id, placeholder})
          {:ok, %{final_state | partial_output: [placeholder]}}

        other ->
          other
      end

    # Skip stream_end for cleared path (already emitted)
    unless match?({:ok, :cleared}, result) do
      emit(stream_id, state.conversation_id, {:stream_end, stream_id})
    end

    case result do
      {:ok, :cleared} ->
        # Return success with empty output — the handoff/continuation flow handles the rest
        reply = %{stream_id: stream_id, status: :cleared, output: "", usage: state.usage}
        {:reply, {:ok, reply}, %{state | status: :idle, stream_id: nil, pending_clear: nil}}

      {:ok, final_state} ->
        Logger.info("Inference complete",
          output_length: length(final_state.partial_output),
          input_tokens: final_state.usage[:input_tokens],
          output_tokens: final_state.usage[:output_tokens],
          cache_read: final_state.usage[:cache_read_input_tokens],
          cache_write: final_state.usage[:cache_creation_input_tokens]
        )

        reply = %{
          stream_id: stream_id,
          status: :complete,
          output: final_state.partial_output |> Enum.reverse() |> Enum.join(),
          usage: final_state.usage,
          cc_session_id: final_state.cc_session_id
        }

        {:reply, {:ok, reply}, %{final_state | status: :idle, stream_id: nil}}

      {:cancelled, final_state} ->
        output = final_state.partial_output |> Enum.reverse() |> Enum.join()
        Logger.info("Inference cancelled", output_length: String.length(output))

        partial = %{
          stream_id: stream_id,
          output: output,
          usage: final_state.usage,
          cc_session_id: final_state.cc_session_id
        }

        {:reply, {:error, :cancelled, partial}, %{final_state | status: :idle, stream_id: nil}}

      {:error, reason} = error ->
        Logger.error("Inference failed", error: inspect(reason))
        {:reply, error, %{state | status: :idle, stream_id: nil}}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    Logger.info("Agent cancelled")
    {:noreply, %{state | status: :cancelled}}
  end

  # --- Inference Loop ---

  defp run_inference(state, stream_id, messages, opts) do
    state = %{state | messages: messages, tool_calls_pending: []}

    case state.llm_backend.stream_chat(messages, opts) do
      {:ok, llm_pid} ->
        ref = Process.monitor(llm_pid)
        result = receive_loop(state, stream_id, llm_pid, ref, opts)

        # Ensure the backend process is fully terminated before returning.
        # The receive_loop exits on {:llm_stop, "end_turn"} when the CC
        # stream parser sees result.success, but the spawned process (and
        # its claude CLI) may still be alive draining the port. Without
        # this wait, a new pass can start a second claude --resume on the
        # same CC session before the first process exits.
        # The tool_use path demonitors and re-enters run_inference, so
        # this only blocks on the final iteration.
        await_backend_exit(llm_pid, ref)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_backend_exit(pid, ref) do
    if Process.alive?(pid) do
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 ->
          Logger.warning("Backend process still alive after 5s, sending shutdown")
          Process.exit(pid, :shutdown)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            2_000 ->
              Logger.warning("Backend process still alive after shutdown, killing")
              Process.exit(pid, :kill)

              receive do
                {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
              after
                1_000 -> :ok
              end
          end
      end
    end

    Process.demonitor(ref, [:flush])
  end

  defp receive_loop(state, stream_id, llm_pid, ref, opts) do
    receive do
      {:llm_text, text} ->
        emit(stream_id, state.conversation_id, {:chunk, stream_id, text})
        state = %{state | partial_output: [text | state.partial_output]}
        receive_loop(state, stream_id, llm_pid, ref, opts)

      {:llm_tool_use, tool_call} ->
        if state.llm_backend.manages_tool_loop?() do
          # CC path: marker and meta-tool calls come through, handle inline
          case Cranium.Inference.Agent.ToolRouter.route(tool_call, state.conversation_id) do
            {:marker, marker_type, input} ->
              {_result, marker} = Cranium.Inference.Agent.MarkerEmitter.handle(marker_type, input)
              emit(stream_id, state.conversation_id, {:chunk, stream_id, {:marker, marker}})
              receive_loop(state, stream_id, llm_pid, ref, opts)

            {:clear, continuation} ->
              # Track clear_context call, execute on end_turn
              Logger.info("CC path: clear_context called",
                conversation_id: state.conversation_id,
                has_continuation: continuation != nil
              )

              receive_loop(%{state | pending_clear: continuation || :no_continuation}, stream_id, llm_pid, ref, opts)

            _ ->
              receive_loop(state, stream_id, llm_pid, ref, opts)
          end
        else
          # Anthropic path: accumulate for batch execution
          state = %{state | tool_calls_pending: [tool_call | state.tool_calls_pending]}
          receive_loop(state, stream_id, llm_pid, ref, opts)
        end

      {:llm_usage, usage} ->
        merged = merge_usage(state.usage, usage)
        receive_loop(%{state | usage: merged}, stream_id, llm_pid, ref, opts)

      {:cc_tool_use, tool_data} ->
        emit(stream_id, state.conversation_id, {:chunk, stream_id, {:tool_use, tool_data}})
        receive_loop(state, stream_id, llm_pid, ref, opts)

      {:cc_tool_result, result_data} ->
        emit(stream_id, state.conversation_id, {:chunk, stream_id, {:tool_result, result_data}})
        receive_loop(state, stream_id, llm_pid, ref, opts)

      {:cc_session, session_id} ->
        # Persist eagerly so a mid-inference process restart doesn't lose the
        # session ID. Without this, a restart creates a fresh CC session and
        # the model loses all conversation history. Skip for ephemeral.
        if state.conversation_id && !Keyword.get(opts, :ephemeral, false) do
          Cranium.Store.update_epoch_session(state.conversation_id, session_id)
        end

        receive_loop(
          %{state | cc_session_id: session_id},
          stream_id,
          llm_pid,
          ref,
          opts
        )

      {:llm_stop, "end_turn"} ->
        # Check for pending clear_context from CC path
        if state.pending_clear do
          continuation = if state.pending_clear == :no_continuation, do: nil, else: state.pending_clear

          Logger.info("CC path: executing pending clear_context",
            conversation_id: state.conversation_id,
            has_continuation: continuation != nil
          )

          # Trigger epoch clear with optional continuation
          clear_opts = [source: "tool"]
          clear_opts = if continuation, do: Keyword.put(clear_opts, :continuation, continuation), else: clear_opts
          Cranium.clear_epoch(state.conversation_id, clear_opts)

          # Emit final message and end stream
          clear_message =
            if continuation do
              "\n\nContext cleared. Continuation will execute after handoff completes."
            else
              "\n\nContext cleared."
            end

          emit(stream_id, state.conversation_id, {:chunk, stream_id, clear_message})
          emit(stream_id, state.conversation_id, {:stream_end, stream_id})

          {:ok, :cleared}
        else
          {:ok, state}
        end

      {:llm_stop, "tool_use"} ->
        Process.demonitor(ref, [:flush])
        execute_tools_and_continue(state, stream_id, opts)

      {:llm_stop, {:error, _status, _body} = error} ->
        {:error, error}

      {:llm_stop, {:error, _reason} = error} ->
        {:error, error}

      {:llm_stop, other} ->
        Logger.warning("Unexpected stop reason", reason: inspect(other))
        {:ok, state}

      # Cancel: kill the LLM streaming process, return partial output
      {:"$gen_cast", :cancel} ->
        Logger.info("Agent cancelled, terminating LLM process")
        Process.unlink(llm_pid)
        Process.exit(llm_pid, :shutdown)
        {:cancelled, state}

      {:DOWN, ^ref, :process, _pid, :normal} ->
        # LLM process exited normally — might not have sent :llm_stop
        {:ok, state}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:llm_crash, reason}}
    end
  end

  defp execute_tools_and_continue(state, stream_id, opts) do
    alias Cranium.Inference.Agent.ToolRouter

    tool_calls = Enum.reverse(state.tool_calls_pending)

    Logger.info("Executing #{length(tool_calls)} tool call(s)")

    # Check for clear_context tool — it triggers early exit
    clear_call =
      Enum.find(tool_calls, fn tc ->
        match?({:clear, _}, ToolRouter.route(tc, state.conversation_id))
      end)

    if clear_call do
      # Execute all non-clear tools first, then handle clear
      other_calls = Enum.reject(tool_calls, fn tc -> tc == clear_call end)

      Enum.each(other_calls, fn tool_call ->
        execute_single_tool(tool_call, stream_id, state.conversation_id, opts)
      end)

      # Clear context and exit pass
      {:clear, continuation} = ToolRouter.route(clear_call, state.conversation_id)

      Logger.info("Executing clear_context tool",
        conversation_id: state.conversation_id,
        has_continuation: continuation != nil
      )

      # Trigger epoch clear with optional continuation
      clear_opts = [source: "tool"]
      clear_opts = if continuation, do: Keyword.put(clear_opts, :continuation, continuation), else: clear_opts
      Cranium.clear_epoch(state.conversation_id, clear_opts)

      # Emit final message and end stream
      clear_message = if continuation do
        "\n\nContext cleared. Continuation will execute after handoff completes."
      else
        "\n\nContext cleared."
      end

      emit(stream_id, state.conversation_id, {:chunk, stream_id, clear_message})
      emit(stream_id, state.conversation_id, {:stream_end, stream_id})

      {:ok, :cleared}
    else
      # No clear — continue normal tool execution flow
      tool_results =
        Enum.map(tool_calls, fn tool_call ->
          result = execute_single_tool(tool_call, stream_id, state.conversation_id, opts)

          %{
            role: "user",
            content: [%{type: "tool_result", tool_use_id: tool_call.id, content: result}]
          }
        end)

      # Build assistant content blocks (text + tool_use)
      assistant_content = build_assistant_content(state.partial_output, tool_calls)

      # Append assistant message + tool results to conversation
      assistant_msg = %{role: "assistant", content: assistant_content}
      updated_messages = state.messages ++ [assistant_msg | tool_results]

      # Clear pending state and re-enter inference
      state = %{state | partial_output: [], tool_calls_pending: []}
      run_inference(state, stream_id, updated_messages, opts)
    end
  end

  defp execute_single_tool(tool_call, stream_id, conversation_id, opts) do
    alias Cranium.Inference.Agent.{ToolRouter, ToolExecutor, MarkerEmitter}

    case ToolRouter.route(tool_call, conversation_id) do
      {:marker, marker_type, input} ->
        {result_text, marker} = MarkerEmitter.handle(marker_type, input)
        emit(stream_id, conversation_id, {:chunk, stream_id, {:marker, marker}})
        result_text

      {:muse, name, input} ->
        working_dir = Keyword.get(opts, :working_dir)
        tool_config = %{
          posture: Keyword.get(opts, :tool_posture, :sandbox),
          rw: Keyword.get(opts, :tool_rw, []),
          ro: Keyword.get(opts, :tool_ro, [])
        }
        Logger.info("Executing muse tool: #{name}", stage: :agent, working_dir: working_dir, posture: tool_config.posture)

        emit_tool_use(stream_id, conversation_id, tool_call, name, input)

        result =
          case Cranium.Muse.exec(name, input, working_dir, tool_config) do
            {:ok, text} -> ToolExecutor.truncate_result(text)
            {:error, reason} -> ~s({"error": "#{inspect(reason)}"})
          end

        emit_tool_result(stream_id, conversation_id, tool_call.id, result)
        result

      {:plugin, plugin_pid, input} ->
        emit_tool_use(stream_id, conversation_id, tool_call, tool_call.name, input)

        epoch_id = Keyword.get(opts, :epoch_id)
        turn_count = Keyword.get(opts, :turn_count, 0)

        tool_call_context = %{
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          turn_count: turn_count,
          tool_call_id: tool_call.id,
          tool_name: tool_call.name,
          input: input
        }

        result =
          case Cranium.Plugin.ConversationSupervisor.dispatch_tool_call(
                 plugin_pid,
                 tool_call_context
               ) do
            {:ok, content} -> ToolExecutor.truncate_result(content)
            {:error, reason} -> ~s({"error": "#{inspect(reason)}"})
          end

        emit_tool_result(stream_id, conversation_id, tool_call.id, result)
        result

      {:execute, module, input} ->
        emit_tool_use(stream_id, conversation_id, tool_call, tool_call.name, input)

        result =
          case ToolExecutor.execute(module, input) do
            {:ok, text} -> ToolExecutor.truncate_result(text)
            {:error, reason} -> ~s({"error": "#{inspect(reason)}"})
          end

        emit_tool_result(stream_id, conversation_id, tool_call.id, result)
        result

      {:clear, _continuation} ->
        # Should not reach here — clear is handled separately
        "Context cleared."

      {:unknown, name} ->
        ~s({"error": "unknown tool: #{name}"})
    end
  end

  defp emit_tool_use(stream_id, conversation_id, tool_call, name, input) do
    payload = %{id: tool_call.id, name: name, input: input}
    emit(stream_id, conversation_id, {:chunk, stream_id, {:tool_use, payload}})
  end

  defp emit_tool_result(stream_id, conversation_id, tool_use_id, content) do
    payload = %{tool_use_id: tool_use_id, content: content}
    emit(stream_id, conversation_id, {:chunk, stream_id, {:tool_result, payload}})
  end

  defp build_assistant_content(partial_output, tool_calls) do
    text = partial_output |> Enum.reverse() |> Enum.join()

    text_blocks =
      if text != "", do: [%{type: "text", text: text}], else: []

    tool_blocks =
      Enum.map(tool_calls, fn tc ->
        %{type: "tool_use", id: tc.id, name: tc.name, input: tc.input}
      end)

    text_blocks ++ tool_blocks
  end

  # Replace with latest usage snapshot rather than summing. Each CC assistant
  # message reports the full context window state for that API call. The last
  # one reflects the actual context size at the end of the turn.
  defp merge_usage(_existing, new), do: new

  # --- Private ---

  defp emit(stream_id, conversation_id, event) do
    # Silent passes (e.g. orientation) suppress raw stream events from the
    # firehose. pass_complete is still broadcast by Harness (not Agent), so
    # PassReactor backpressure continues to work. The flag is set per-process
    # in handle_call({:infer, ...}) via Process.put.
    unless Process.get(:emit_silent) do
      Cranium.Events.broadcast(stream_id, conversation_id, event)
    end
  end

  defp backend_module do
    Application.get_env(:cranium, :backends)[:llm] || Cranium.Backend.LLM.Anthropic
  end
end

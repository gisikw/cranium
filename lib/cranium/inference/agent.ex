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

  alias Cranium.Inference.SuppressedThought

  @registry Cranium.Inference.ConversationRegistry

  use TypedStruct

  typedstruct do
    field :conversation_id, String.t()
    field :epoch_pid, pid() | nil
    field :stream_id, String.t() | nil
    field :llm_backend, module()
    field :cc_session_id, String.t() | nil

    field :status, :idle | :inferring | :tool_use | :awaiting_async_tools | :cancelled,
      default: :idle

    field :messages, list(), default: []
    field :tool_calls_pending, list(), default: []
    field :async_tasks_outstanding, list(), default: []
    field :async_results_pending, list(), default: []
    field :partial_output, list(), default: []
    field :assistant_content_blocks, list(), default: []
    field :intermediate_messages, list(), default: []
    field :usage, map(), default: %{input_tokens: 0, output_tokens: 0}
    # For CC path: tracks pending clear_context call (nil or continuation string)
    field :pending_clear, String.t() | nil, default: nil
    # Filters <suppressed>...</suppressed> spans at stream ingress, before
    # any fan-out (chunks, partial_output, turn state, content blocks).
    field :suppression, SuppressedThought.t() | nil, default: nil
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
        assistant_content_blocks: [],
        intermediate_messages: [],
        async_tasks_outstanding: [],
        async_results_pending: [],
        usage: %{input_tokens: 0, output_tokens: 0},
        suppression: SuppressedThought.new()
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

    # Register turn state for snapshot reconnect recovery (crn-a0f5).
    # This lets Snapshot.detect_active_turn read accumulated state
    # without calling into the blocked GenServer.
    turn_state = %{
      stream_id: stream_id,
      started_at: DateTime.utc_now(),
      accumulated_text: "",
      accumulated_parts: [],
      pending_tool_calls: []
    }

    register_turn_state(state.conversation_id, turn_state)

    # Start the LLM backend stream — skip tool definitions for managed-loop backends
    # or when tools are explicitly disabled (e.g. orientation passes).
    # CC manages its own tool loop, so orientation gets a read-only whitelist string.
    # Non-CC backends get no tools on orientation — models like GPT-5.5 will try
    # to explore the filesystem instead of journaling if tools are present.
    tools_disabled = context[:tools_disabled] == true

    tools =
      cond do
        tools_disabled and state.llm_backend.manages_tool_loop?() ->
          "Read,Glob,Grep,WebFetch,WebSearch,Task"

        tools_disabled ->
          []

        state.llm_backend.manages_tool_loop?() ->
          []

        true ->
          Cranium.Inference.Agent.ToolRouter.tool_definitions(state.conversation_id)
      end

    disposition = Map.get(context, :disposition, ["text"])

    opts = [
      system: system,
      system_prompt_pre: context[:system_prompt_pre],
      system_prompt_post: context[:system_prompt_post],
      max_tokens: Map.get(context, :max_tokens, 8192),
      tools: tools,
      tools_disabled: tools_disabled,
      cc_session_id: context[:cc_session_id],
      working_dir: context[:working_dir],
      conversation_id: context[:conversation_id],
      epoch_id: context[:epoch_id],
      model: context[:model],
      thinking: context[:thinking],
      router_profile: context[:router_profile],
      backend_config: context[:backend_config],
      ephemeral: context[:ephemeral],
      effort_level: if("audio" in disposition, do: "low"),
      tool_posture: context[:tool_posture] || :sandbox,
      tool_rw: context[:tool_rw] || [],
      tool_ro: context[:tool_ro] || [],
      exec_endpoint: context[:exec_endpoint],
      depth: context[:depth]
    ]

    result =
      case run_inference(state, stream_id, messages, opts) do
        {:ok, :cleared} = cleared ->
          cancel_async_tasks(state, :cancelled)
          cleared

        other ->
          other
      end

    # End of stream: release any held-back literal tail from the suppression
    # filter and journal an unclosed span (fail closed — it is never emitted).
    result = flush_suppression(result, stream_id, state.conversation_id, opts)

    # If inference succeeded but produced no output (e.g. model safety refusal
    # returning empty string), emit a visible message so the client isn't left
    # staring at nothing.
    result =
      case result do
        {:ok, :cleared} ->
          # clear_context path already emitted stream_end, skip post-processing
          {:ok, :cleared}

        {:ok, final_state} when final_state.partial_output == [] ->
          if SuppressedThought.spans(final_state.suppression) == [] do
            Logger.warning("Model returned empty response, emitting placeholder",
              conversation_id: state.conversation_id
            )

            placeholder = "[Model returned empty response]"
            emit(stream_id, state.conversation_id, {:chunk, stream_id, placeholder})
            {:ok, %{final_state | partial_output: [placeholder]}}
          else
            # Everything the model said was suppressed — deliver silence, not
            # a placeholder that misreports an empty response.
            {:ok, final_state}
          end

        other ->
          other
      end

    # Skip stream_end for cleared path (already emitted)
    unless match?({:ok, :cleared}, result) do
      emit(stream_id, state.conversation_id, {:stream_end, stream_id})
    end

    # Clean up turn state registration (crn-a0f5)
    unregister_turn_state(state.conversation_id)

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
          final_message_content: final_assistant_content(final_state),
          intermediate_messages: final_state.intermediate_messages,
          usage: final_state.usage,
          cc_session_id: final_state.cc_session_id
        }

        {:reply, {:ok, reply}, %{final_state | status: :idle, stream_id: nil}}

      {:cancelled, final_state} ->
        output = final_state.partial_output |> Enum.reverse() |> Enum.join()
        Logger.info("Inference cancelled", output_length: String.length(output))

        interrupted_context = build_interrupted_context(final_state)

        partial = %{
          stream_id: stream_id,
          output: output,
          intermediate_messages: final_state.intermediate_messages,
          interrupted_context: interrupted_context,
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

  # Late-arriving LLM messages that land after the receive loop exits.
  # Safe to ignore — usage is already captured during inference.
  @impl true
  def handle_info({:llm_usage, _}, state), do: {:noreply, state}
  def handle_info({:llm_text, _}, state), do: {:noreply, state}
  def handle_info({:llm_assistant_content, _}, state), do: {:noreply, state}
  def handle_info({:llm_stop, _}, state), do: {:noreply, state}
  def handle_info({:llm_tool_use, _}, state), do: {:noreply, state}

  def handle_info({:async_tool_complete, _task_id, _status, _result}, state),
    do: {:noreply, state}

  def handle_info({ref, _value}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref),
    do: {:noreply, state}

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
        # Suppressed spans are stripped here, at stream ingress — upstream of
        # every fan-out point (chunk broadcast, partial_output, turn state).
        {visible, closed_spans, suppression} = SuppressedThought.push(state.suppression, text)
        journal_spans(state.conversation_id, opts, closed_spans)
        state = %{state | suppression: suppression}

        state =
          if visible == "" do
            state
          else
            emit(stream_id, state.conversation_id, {:chunk, stream_id, visible})

            update_turn_state(state.conversation_id, fn ts ->
              %{ts | accumulated_text: ts.accumulated_text <> visible}
            end)

            %{state | partial_output: [visible | state.partial_output]}
          end

        receive_loop(state, stream_id, llm_pid, ref, opts)

      {:llm_assistant_content, content_blocks} when is_list(content_blocks) ->
        # Native blocks carry the same text the stream did — strip them too so
        # final_message_content and interrupted context stay clean. The filter
        # state dedupes spans the stream already journaled.
        {blocks, new_spans, suppression} =
          content_blocks
          |> normalize_content_blocks()
          |> SuppressedThought.strip_blocks(state.suppression)

        journal_spans(state.conversation_id, opts, new_spans)

        state = %{
          state
          | assistant_content_blocks: state.assistant_content_blocks ++ blocks,
            suppression: suppression
        }

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

              receive_loop(
                %{state | pending_clear: continuation || :no_continuation},
                stream_id,
                llm_pid,
                ref,
                opts
              )

            _ ->
              receive_loop(state, stream_id, llm_pid, ref, opts)
          end
        else
          # Anthropic path: accumulate for batch execution
          state = %{state | tool_calls_pending: [tool_call | state.tool_calls_pending]}
          receive_loop(state, stream_id, llm_pid, ref, opts)
        end

      {:async_tool_complete, task_id, status, result} ->
        state = complete_async_task(state, task_id, status, result)
        receive_loop(state, stream_id, llm_pid, ref, opts)

      {:llm_usage, usage} ->
        merged = merge_usage(state.usage, usage)
        receive_loop(%{state | usage: merged}, stream_id, llm_pid, ref, opts)

      {:cc_tool_use, tool_data} ->
        emit(stream_id, state.conversation_id, {:chunk, stream_id, {:tool_use, tool_data}})
        # Drain accumulated text + tool_use into one assistant message (matches muse path)
        text = state.partial_output |> Enum.reverse() |> Enum.join()
        text_blocks = if text != "", do: [%{type: "text", text: text}], else: []

        tool_block = %{
          type: "tool_use",
          id: tool_data.id,
          name: tool_data.name,
          input: tool_data.input
        }

        assistant_msg = %{role: "assistant", content: text_blocks ++ [tool_block]}

        state = %{
          state
          | partial_output: [],
            intermediate_messages: state.intermediate_messages ++ [assistant_msg]
        }

        update_turn_state(state.conversation_id, fn ts ->
          %{
            ts
            | accumulated_text: "",
              pending_tool_calls:
                ts.pending_tool_calls ++
                  [
                    %{id: tool_data.id, name: tool_data.name, status: "running"}
                  ]
          }
        end)

        receive_loop(state, stream_id, llm_pid, ref, opts)

      {:cc_tool_result, result_data} ->
        emit(stream_id, state.conversation_id, {:chunk, stream_id, {:tool_result, result_data}})
        # Accumulate for persistence (same content block format as muse path)
        user_msg = %{
          role: "user",
          content: [
            %{
              type: "tool_result",
              tool_use_id: result_data.tool_use_id,
              content: result_data.content
            }
          ]
        }

        state = %{state | intermediate_messages: state.intermediate_messages ++ [user_msg]}

        update_turn_state(state.conversation_id, fn ts ->
          tool_use_id = result_data.tool_use_id

          updated_calls =
            Enum.map(ts.pending_tool_calls, fn tc ->
              if tc.id == tool_use_id, do: %{tc | status: "complete"}, else: tc
            end)

          %{ts | pending_tool_calls: updated_calls}
        end)

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
          continuation =
            if state.pending_clear == :no_continuation, do: nil, else: state.pending_clear

          Logger.info("CC path: executing pending clear_context",
            conversation_id: state.conversation_id,
            has_continuation: continuation != nil
          )

          # Trigger epoch clear with optional continuation
          clear_opts = [source: "tool"]

          clear_opts =
            if continuation,
              do: Keyword.put(clear_opts, :continuation, continuation),
              else: clear_opts

          Cranium.clear_epoch(state.conversation_id, clear_opts)

          # The cleared path discards agent state — journal an open suppressed
          # span now so the trace survives the clear.
          journal_suppression_finish(state, opts)

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
          maybe_finish_or_wait_for_async(state, stream_id, opts)
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
        state = cancel_async_tasks(state)
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
        ToolRouter.async_mode(tc) in [nil, ""] and
          match?({:clear, _}, ToolRouter.route(tc, state.conversation_id))
      end)

    if clear_call do
      # Execute all non-clear tools first, then handle clear
      other_calls = Enum.reject(tool_calls, fn tc -> tc == clear_call end)

      {_, state} =
        Enum.map_reduce(other_calls, state, fn tool_call, acc_state ->
          {_result, acc_state} = execute_tool_for_batch(tool_call, stream_id, acc_state, opts)
          {:ok, acc_state}
        end)

      # Clear context and exit pass. Any pass-scoped async work must not leak
      # across the epoch boundary.
      state = cancel_async_tasks(state, :cancelled)
      {:clear, continuation} = ToolRouter.route(clear_call, state.conversation_id)

      Logger.info("Executing clear_context tool",
        conversation_id: state.conversation_id,
        has_continuation: continuation != nil
      )

      # Trigger epoch clear with optional continuation
      clear_opts = [source: "tool"]

      clear_opts =
        if continuation,
          do: Keyword.put(clear_opts, :continuation, continuation),
          else: clear_opts

      Cranium.clear_epoch(state.conversation_id, clear_opts)

      # The cleared path discards agent state — journal an open suppressed
      # span now so the trace survives the clear.
      journal_suppression_finish(state, opts)

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
      # No clear — continue normal tool execution flow
      {tool_result_messages, state} =
        Enum.map_reduce(tool_calls, state, fn tool_call, acc_state ->
          {result, acc_state} = execute_tool_for_batch(tool_call, stream_id, acc_state, opts)

          message = %{
            role: "user",
            content: [%{type: "tool_result", tool_use_id: tool_call.id, content: result}]
          }

          {message, acc_state}
        end)

      # Build assistant content blocks (text + tool_use)
      assistant_content = build_assistant_content(state)

      # Append assistant message + tool results to conversation
      assistant_msg = %{role: "assistant", content: assistant_content}
      updated_messages = state.messages ++ [assistant_msg | tool_result_messages]

      {updated_messages, state, async_injections} =
        inject_ready_async_results(updated_messages, state)

      # Accumulate intermediate messages for persistence
      intermediate = [assistant_msg | tool_result_messages] ++ async_injections

      # Clear pending state and re-enter inference
      state = %{
        state
        | partial_output: [],
          assistant_content_blocks: [],
          tool_calls_pending: [],
          intermediate_messages: state.intermediate_messages ++ intermediate
      }

      run_inference(state, stream_id, updated_messages, opts)
    end
  end

  defp execute_tool_for_batch(tool_call, stream_id, state, opts) do
    alias Cranium.Inference.Agent.ToolRouter

    mode = ToolRouter.async_mode(tool_call)
    route = ToolRouter.route(tool_call, state.conversation_id)

    cond do
      mode in [nil, "", nil] ->
        {execute_single_tool(tool_call, stream_id, state.conversation_id, opts), state}

      mode != "single_pass" and mode != :single_pass ->
        emit_tool_use(
          stream_id,
          state.conversation_id,
          tool_call,
          tool_call.name,
          tool_call.input
        )

        result = ~s({"error":"unsupported cranium_async_mode: #{mode}"})
        emit_tool_result(stream_id, state.conversation_id, tool_call.id, result)
        {result, state}

      not ToolRouter.async_executable_route?(route) ->
        emit_tool_use(
          stream_id,
          state.conversation_id,
          tool_call,
          tool_call.name,
          tool_call.input
        )

        result = ~s({"error":"tool does not support cranium_async_mode"})
        emit_tool_result(stream_id, state.conversation_id, tool_call.id, result)
        {result, state}

      length(state.async_tasks_outstanding) >= max_async_tasks_per_pass() ->
        emit_tool_use(
          stream_id,
          state.conversation_id,
          tool_call,
          tool_call.name,
          tool_call.input
        )

        result = ~s({"error":"async task limit reached for this pass"})
        emit_tool_result(stream_id, state.conversation_id, tool_call.id, result)
        {result, state}

      true ->
        start_async_tool_task(tool_call, route, stream_id, state, opts)
    end
  end

  defp start_async_tool_task(tool_call, route, stream_id, state, opts) do
    task_id = "async_" <> Ecto.UUID.generate()
    parent = self()
    clean_tool_call = Cranium.Inference.Agent.ToolRouter.strip_async_mode(tool_call)
    clean_route = reroute_with_clean_input(route, clean_tool_call.input)

    emit_tool_use(stream_id, state.conversation_id, tool_call, tool_call.name, tool_call.input)

    emit(
      stream_id,
      state.conversation_id,
      {:chunk, stream_id,
       {:async_task,
        %{
          event_type: :started,
          async_task_id: task_id,
          tool_call_id: tool_call.id,
          tool_name: tool_call.name,
          async_mode: :single_pass,
          status: :running
        }}}
    )

    task =
      Task.Supervisor.async_nolink(Cranium.Inference.AsyncToolTaskSupervisor, fn ->
        try do
          result = execute_routed_tool(clean_tool_call, clean_route, state.conversation_id, opts)
          send(parent, {:async_tool_complete, task_id, :succeeded, result})
        rescue
          e ->
            send(
              parent,
              {:async_tool_complete, task_id, :failed, ~s({"error":"#{Exception.message(e)}"})}
            )
        catch
          kind, reason ->
            send(
              parent,
              {:async_tool_complete, task_id, :failed,
               ~s({"error":"async task #{kind}: #{inspect(reason)}"})}
            )
        end
      end)

    async_task = %{
      id: task_id,
      pid: task.pid,
      ref: task.ref,
      tool_call: clean_tool_call,
      tool_name: tool_call.name,
      stream_id: stream_id,
      order: System.unique_integer([:monotonic])
    }

    ack =
      Jason.encode!(%{
        status: "accepted",
        execution: "async",
        async_mode: "single_pass",
        async_task_id: task_id,
        message:
          "Tool call accepted for background execution. The result will be injected before this pass completes."
      })

    emit_tool_result(stream_id, state.conversation_id, tool_call.id, ack)
    {ack, %{state | async_tasks_outstanding: [async_task | state.async_tasks_outstanding]}}
  end

  defp complete_async_task(state, task_id, status, result) do
    {task, outstanding} = pop_async_task(state.async_tasks_outstanding, task_id)

    if task do
      Process.demonitor(task.ref, [:flush])
      event_type = if status == :succeeded, do: :completed, else: status
      preview = result |> to_string() |> String.slice(0, async_result_preview_max_bytes())

      emit(
        task.stream_id,
        state.conversation_id,
        {:chunk, task.stream_id,
         {:async_task,
          %{
            event_type: event_type,
            async_task_id: task_id,
            tool_call_id: task.tool_call.id,
            tool_name: task.tool_name,
            async_mode: :single_pass,
            status: status,
            preview: preview
          }}}
      )

      pending =
        if status in [:succeeded, :failed] do
          [
            %{
              async_task_id: task_id,
              tool_call_id: task.tool_call.id,
              tool_name: task.tool_name,
              status: status,
              content: result,
              order: task.order
            }
            | state.async_results_pending
          ]
        else
          state.async_results_pending
        end

      %{state | async_tasks_outstanding: outstanding, async_results_pending: pending}
    else
      state
    end
  end

  defp pop_async_task(tasks, task_id) do
    task = Enum.find(tasks, &(&1.id == task_id))
    {task, Enum.reject(tasks, &(&1.id == task_id))}
  end

  defp append_current_assistant_message(messages, state) do
    case build_assistant_content(state) do
      [] ->
        {messages, []}

      content ->
        message = %{role: "assistant", content: content}
        {messages ++ [message], [message]}
    end
  end

  defp maybe_finish_or_wait_for_async(state, stream_id, opts) do
    cond do
      state.async_results_pending != [] ->
        {messages, assistant_messages} = append_current_assistant_message(state.messages, state)
        {messages, state, injections} = inject_ready_async_results(messages, state)

        state = %{
          state
          | intermediate_messages:
              state.intermediate_messages ++ assistant_messages ++ injections,
            partial_output: [],
            assistant_content_blocks: []
        }

        run_inference(state, stream_id, messages, opts)

      state.async_tasks_outstanding != [] ->
        wait_for_async_then_continue(%{state | status: :awaiting_async_tools}, stream_id, opts)

      true ->
        {:ok, state}
    end
  end

  defp wait_for_async_then_continue(state, stream_id, opts) do
    receive do
      {:async_tool_complete, task_id, status, result} ->
        state
        |> complete_async_task(task_id, status, result)
        |> maybe_finish_or_wait_for_async(stream_id, opts)

      {ref, _value} when is_reference(ref) ->
        wait_for_async_then_continue(state, stream_id, opts)

      {:DOWN, ref, :process, _pid, reason} ->
        case Enum.find(state.async_tasks_outstanding, &(&1.ref == ref)) do
          nil ->
            wait_for_async_then_continue(state, stream_id, opts)

          task ->
            result = ~s({"error":"async task exited: #{inspect(reason)}"})

            state
            |> complete_async_task(task.id, :failed, result)
            |> maybe_finish_or_wait_for_async(stream_id, opts)
        end

      {:"$gen_cast", :cancel} ->
        state = cancel_async_tasks(state)
        {:cancelled, state}
    end
  end

  defp inject_ready_async_results(messages, state) do
    results = Enum.sort_by(state.async_results_pending, & &1.order)

    injections =
      Enum.map(results, fn result ->
        status = if result.status == :succeeded, do: "succeeded", else: "failed"

        content =
          "<async-tool-result async_task_id=\"#{result.async_task_id}\" tool_call_id=\"#{result.tool_call_id}\" tool_name=\"#{result.tool_name}\" status=\"#{status}\">\n#{result.content}\n</async-tool-result>"

        %{role: "user", content: content}
      end)

    {messages ++ injections, %{state | async_results_pending: []}, injections}
  end

  defp cancel_async_tasks(state) do
    cancel_async_tasks(state, :cancelled)
  end

  defp cancel_async_tasks(state, terminal_status) do
    tasks = state.async_tasks_outstanding

    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid), do: Process.exit(task.pid, :shutdown)
    end)

    remaining_after_shutdown = wait_for_async_task_shutdown(tasks, async_cancel_grace_ms())

    Enum.each(remaining_after_shutdown, fn task ->
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
    end)

    abandoned = wait_for_async_task_shutdown(remaining_after_shutdown, async_kill_grace_ms())
    killed_ids = MapSet.new(Enum.map(remaining_after_shutdown -- abandoned, & &1.id))
    abandoned_ids = MapSet.new(Enum.map(abandoned, & &1.id))

    Enum.reduce(tasks, state, fn task, acc ->
      status =
        cond do
          MapSet.member?(abandoned_ids, task.id) -> :abandoned
          MapSet.member?(killed_ids, task.id) -> :killed
          true -> terminal_status
        end

      complete_async_task(acc, task.id, status, ~s({"error":"async task #{status}"}))
    end)
  end

  defp wait_for_async_task_shutdown(tasks, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_async_task_shutdown(tasks, deadline, [])
  end

  defp wait_for_async_task_shutdown([], _deadline, remaining), do: Enum.reverse(remaining)

  defp wait_for_async_task_shutdown([task | rest], deadline, remaining) do
    now = System.monotonic_time(:millisecond)
    timeout = max(deadline - now, 0)

    if Process.alive?(task.pid) do
      receive do
        {ref, _value} when ref == task.ref ->
          wait_for_async_task_shutdown(rest, deadline, remaining)

        {:DOWN, ref, :process, _pid, _reason} when ref == task.ref ->
          wait_for_async_task_shutdown(rest, deadline, remaining)
      after
        timeout ->
          wait_for_async_task_shutdown(rest, deadline, [task | remaining])
      end
    else
      wait_for_async_task_shutdown(rest, deadline, remaining)
    end
  end

  defp reroute_with_clean_input({:muse, name, _}, input), do: {:muse, name, input}
  defp reroute_with_clean_input({:plugin, pid, _}, input), do: {:plugin, pid, input}
  defp reroute_with_clean_input({:macro, name, _}, input), do: {:macro, name, input}
  defp reroute_with_clean_input({:execute, module, _}, input), do: {:execute, module, input}
  defp reroute_with_clean_input(route, _input), do: route

  defp execute_routed_tool(tool_call, route, conversation_id, opts) do
    case route do
      {:muse, name, input} ->
        working_dir = Keyword.get(opts, :working_dir)

        tool_config = %{
          posture: Keyword.get(opts, :tool_posture, :sandbox),
          rw: Keyword.get(opts, :tool_rw, []),
          ro: Keyword.get(opts, :tool_ro, []),
          exec_endpoint: Keyword.get(opts, :exec_endpoint),
          depth: Keyword.get(opts, :depth)
        }

        case Cranium.Muse.exec(name, input, working_dir, tool_config) do
          {:ok, text} -> Cranium.Inference.Agent.ToolExecutor.truncate_result(text)
          {:error, reason} -> ~s({"error": "#{inspect(reason)}"})
        end

      {:plugin, plugin_pid, input} ->
        tool_call_context = %{
          conversation_id: conversation_id,
          epoch_id: Keyword.get(opts, :epoch_id),
          turn_count: Keyword.get(opts, :turn_count, 0),
          tool_call_id: tool_call.id,
          tool_name: tool_call.name,
          input: input
        }

        case Cranium.Plugin.ConversationSupervisor.dispatch_tool_call(
               plugin_pid,
               tool_call_context
             ) do
          {:ok, content} -> Cranium.Inference.Agent.ToolExecutor.truncate_result(content)
          {:error, reason} -> ~s({"error": "#{inspect(reason)}"})
        end

      {:macro, name, input} ->
        macro_context = %{
          conversation_id: conversation_id,
          epoch_id: Keyword.get(opts, :epoch_id),
          turn_count: Keyword.get(opts, :turn_count, 0),
          room_name: conversation_id
        }

        if name == "search_macros" do
          query = input["query"] || ""

          case Cranium.Macro.Registry.search(query) do
            [] ->
              "No macros found matching \"#{query}\"."

            results ->
              Enum.map_join(results, "\n", fn m -> "- **#{m.name}**: #{m.description}" end)
          end
        else
          case Cranium.Macro.Engine.execute_tool(name, input, macro_context) do
            {:ok, text} -> Cranium.Inference.Agent.ToolExecutor.truncate_result(text)
            {:error, reason} -> ~s({"error": "#{inspect(reason)}"})
          end
        end

      {:execute, module, input} ->
        case Cranium.Inference.Agent.ToolExecutor.execute(module, input,
               depth: Keyword.get(opts, :depth),
               conversation_id: conversation_id
             ) do
          {:ok, text} -> Cranium.Inference.Agent.ToolExecutor.truncate_result(text)
          {:error, reason} -> ~s({"error": "#{inspect(reason)}"})
        end
    end
  end

  defp max_async_tasks_per_pass, do: Application.get_env(:cranium, :max_async_tasks_per_pass, 5)

  defp final_assistant_content(state) do
    blocks = normalize_content_blocks(state.assistant_content_blocks)

    if blocks == [] do
      nil
    else
      blocks
    end
  end

  defp async_result_preview_max_bytes,
    do: Application.get_env(:cranium, :async_result_preview_max_bytes, 1000)

  defp async_cancel_grace_ms, do: Application.get_env(:cranium, :async_cancel_grace_ms, 250)

  defp async_kill_grace_ms, do: Application.get_env(:cranium, :async_kill_grace_ms, 100)

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
          ro: Keyword.get(opts, :tool_ro, []),
          exec_endpoint: Keyword.get(opts, :exec_endpoint),
          depth: Keyword.get(opts, :depth)
        }

        Logger.info("Executing muse tool: #{name}",
          stage: :agent,
          working_dir: working_dir,
          posture: tool_config.posture
        )

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

      {:macro, name, input} ->
        emit_tool_use(stream_id, conversation_id, tool_call, name, input)

        epoch_id = Keyword.get(opts, :epoch_id)
        turn_count = Keyword.get(opts, :turn_count, 0)

        macro_context = %{
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          turn_count: turn_count,
          room_name: conversation_id
        }

        result =
          if name == "search_macros" do
            query = input["query"] || ""
            results = Cranium.Macro.Registry.search(query)
            Logger.info("search_macros query=#{inspect(query)} results=#{length(results)}")

            if results == [] do
              "No macros found matching \"#{query}\"."
            else
              results
              |> Enum.map(fn m -> "- **#{m.name}**: #{m.description}" end)
              |> Enum.join("\n")
            end
          else
            case Cranium.Macro.Engine.execute_tool(name, input, macro_context) do
              {:ok, text} -> ToolExecutor.truncate_result(text)
              {:error, reason} -> ~s({"error": "#{inspect(reason)}"})
            end
          end

        emit_tool_result(stream_id, conversation_id, tool_call.id, result)
        result

      {:execute, module, input} ->
        emit_tool_use(stream_id, conversation_id, tool_call, tool_call.name, input)

        execute_opts = [depth: Keyword.get(opts, :depth), conversation_id: conversation_id]

        result =
          case ToolExecutor.execute(module, input, execute_opts) do
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

  defp build_interrupted_context(state) do
    sections =
      []
      |> append_content_block_sections(build_assistant_content(state))
      |> append_pending_tool_sections(state.tool_calls_pending)
      |> append_async_task_sections(state.async_tasks_outstanding)
      |> append_async_result_sections(state.async_results_pending)
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n\n")
  end

  defp append_content_block_sections(sections, blocks) when is_list(blocks) do
    sections ++ Enum.flat_map(blocks, &content_block_sections/1)
  end


  defp append_pending_tool_sections(sections, tool_calls) when is_list(tool_calls) do
    sections ++
      (tool_calls
       |> Enum.reverse()
       |> Enum.map(fn tc -> "> **#{tool_call_name(tc)}**: `#{tool_call_detail(tc)}`" end))
  end

  defp append_pending_tool_sections(sections, _), do: sections

  defp append_async_task_sections(sections, tasks) when is_list(tasks) do
    sections ++
      Enum.map(tasks, fn task ->
        "> **#{task[:tool_name] || "async tool"}**: async task #{task[:id] || "unknown"} was running when cancelled"
      end)
  end

  defp append_async_task_sections(sections, _), do: sections

  defp append_async_result_sections(sections, results) when is_list(results) do
    sections ++
      Enum.map(results, fn result ->
        status = result[:status] || "completed"
        tool_name = result[:tool_name] || "async tool"
        "> **#{tool_name}**: async task #{status} before cancellation"
      end)
  end

  defp append_async_result_sections(sections, _), do: sections

  defp content_block_sections(blocks) when is_list(blocks),
    do: Enum.flat_map(blocks, &content_block_sections/1)

  defp content_block_sections(block) when is_map(block) do
    case map_value(block, "type") do
      "text" ->
        case map_value(block, "text") do
          text when is_binary(text) and text != "" -> [text]
          _ -> []
        end

      "tool_use" ->
        name = map_value(block, "tool_name") || map_value(block, "name") || "tool"
        input = map_value(block, "tool_input") || map_value(block, "input") || %{}
        ["> **#{name}**: `#{tool_detail(name, input)}`"]

      "tool_result" ->
        result_for =
          map_value(block, "tool_result_for") || map_value(block, "tool_use_id") || "tool"

        output = map_value(block, "tool_output") || map_value(block, "content") || ""
        ["> **#{result_for} result**: `#{truncate_inline(output)}`"]

      _ ->
        []
    end
  end

  defp content_block_sections(_), do: []

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp map_value(_, _), do: nil

  defp tool_call_name(tc), do: map_value(tc, "tool_name") || map_value(tc, "name") || "tool"

  defp tool_call_detail(tc),
    do:
      tool_detail(
        tool_call_name(tc),
        map_value(tc, "tool_input") || map_value(tc, "input") || %{}
      )

  defp tool_detail(_name, input) when is_map(input) do
    cond do
      map_value(input, "command") -> truncate_inline(map_value(input, "command"))
      map_value(input, "file_path") -> truncate_inline(map_value(input, "file_path"))
      map_value(input, "path") -> truncate_inline(map_value(input, "path"))
      map_value(input, "pattern") -> truncate_inline(map_value(input, "pattern"))
      true -> truncate_inline(input)
    end
  end

  defp tool_detail(_name, input), do: truncate_inline(input)

  defp truncate_inline(value) do
    value
    |> inspect(limit: 20, printable_limit: 200)
    |> String.replace("`", "\\`")
    |> String.slice(0, 240)
  end

  defp build_assistant_content(state) do
    native_blocks = normalize_content_blocks(state.assistant_content_blocks)
    tool_calls = Enum.reverse(state.tool_calls_pending)

    if native_blocks == [] do
      build_assistant_content_from_legacy_stream(state.partial_output, tool_calls)
    else
      native_blocks
    end
  end

  defp build_assistant_content_from_legacy_stream(partial_output, tool_calls) do
    text = partial_output |> Enum.reverse() |> Enum.join()

    text_blocks =
      if text != "", do: [%{type: "text", text: text}], else: []

    tool_blocks =
      Enum.map(tool_calls, fn tc ->
        %{type: "tool_use", id: tc.id, name: tc.name, input: tc.input}
      end)

    text_blocks ++ tool_blocks
  end

  defp normalize_content_blocks(blocks) when is_list(blocks) do
    Enum.map(blocks, &normalize_content_block/1)
  end

  defp normalize_content_block(block) when is_map(block) do
    type = block_value(block, "type")

    case type do
      "text" ->
        %{type: "text", text: block_value(block, "text") || ""}

      "thinking" ->
        %{
          type: "thinking",
          text: block_value(block, "text") || block_value(block, "thinking") || ""
        }

      "tool_use" ->
        %{
          type: "tool_use",
          id: block_value(block, "tool_use_id") || block_value(block, "id"),
          name: block_value(block, "tool_name") || block_value(block, "name"),
          input: block_value(block, "tool_input") || block_value(block, "input") || %{}
        }

      other when is_binary(other) ->
        block
        |> stringify_keys()
        |> Map.put("type", other)

      _ ->
        stringify_keys(block)
    end
  end

  defp normalize_content_block(other), do: %{type: "text", text: to_string(other)}

  defp block_value(map, key) when is_map(map) and is_binary(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, String.to_atom(key)) -> Map.get(map, String.to_atom(key))
      true -> nil
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  # Replace with latest usage snapshot rather than summing. Each CC assistant
  # message reports the full context window state for that API call. The last
  # one reflects the actual context size at the end of the turn.
  defp merge_usage(_existing, new), do: new

  # --- Private ---

  # --- Turn state for snapshot reconnect recovery (crn-a0f5) ---

  defp update_turn_state(conversation_id, fun) when is_function(fun, 1) do
    Registry.update_value(@registry, {conversation_id, :turn_state}, fun)
  rescue
    ArgumentError -> :error
  end

  defp unregister_turn_state(conversation_id) do
    Registry.unregister(@registry, {conversation_id, :turn_state})
  rescue
    ArgumentError -> :ok
  end

  defp register_turn_state(conversation_id, turn_state) do
    Registry.register(@registry, {conversation_id, :turn_state}, turn_state)
  rescue
    ArgumentError -> {:error, :no_registry}
  end

  # --- Suppressed thought (discretion channel) ---

  defp flush_suppression({tag, %__MODULE__{} = final_state}, stream_id, conversation_id, opts)
       when tag in [:ok, :cancelled] do
    {visible, new_spans, suppression} = SuppressedThought.finish(final_state.suppression)
    journal_spans(conversation_id, opts, new_spans)

    final_state =
      if visible == "" do
        %{final_state | suppression: suppression}
      else
        emit(stream_id, conversation_id, {:chunk, stream_id, visible})

        %{
          final_state
          | suppression: suppression,
            partial_output: [visible | final_state.partial_output]
        }
      end

    {tag, final_state}
  end

  defp flush_suppression(result, _stream_id, _conversation_id, _opts), do: result

  defp journal_suppression_finish(state, opts) do
    {_visible, new_spans, _suppression} = SuppressedThought.finish(state.suppression)
    journal_spans(state.conversation_id, opts, new_spans)
  end

  defp journal_spans(_conversation_id, _opts, []), do: :ok

  defp journal_spans(conversation_id, opts, spans) do
    Cranium.Store.SuppressionJournal.append(conversation_id, Keyword.get(opts, :epoch_id), spans)
  end

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
    Application.get_env(:cranium, :backends)[:llm] || Cranium.Backend.LLM.Tiamat
  end
end

defmodule Cranium.Agent do
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

  defstruct [
    :conversation_id,
    :epoch_pid,
    :stream_id,
    :llm_backend,
    :cc_session_id,
    status: :idle,
    messages: [],
    tool_calls_pending: [],
    partial_output: [],
    usage: %{input_tokens: 0, output_tokens: 0}
  ]

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          epoch_pid: pid() | nil,
          stream_id: String.t() | nil,
          llm_backend: module(),
          cc_session_id: String.t() | nil,
          status: :idle | :inferring | :tool_use | :cancelled,
          messages: list(),
          tool_calls_pending: list(),
          partial_output: list(),
          usage: map()
        }

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

  `egress_pid` receives streaming output chunks.
  Returns when inference is complete (including any tool call loops).
  """
  @spec infer(pid(), map(), pid()) :: {:ok, map()} | {:error, term()}
  def infer(pid, context, egress_pid) do
    GenServer.call(pid, {:infer, context, egress_pid}, :infinity)
  end

  # --- GenServer Implementation ---

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    llm_backend = backend_module()

    Logger.metadata(conversation_id: conversation_id, stage: :agent)
    Logger.info("Agent started")

    state = %__MODULE__{
      conversation_id: conversation_id,
      epoch_pid: Keyword.get(opts, :epoch_pid),
      llm_backend: llm_backend
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:infer, context, egress_pid}, _from, state) do
    stream_id = context[:stream_id] || Cranium.Stage.new_stream_id()

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

    # Signal stream start to Egress
    metadata = %{
      conversation_id: state.conversation_id,
      content_type: :llm_response,
      mode: Map.get(context, :mode, :text),
      disposition: Map.get(context, :disposition, ["text"]),
      source: :agent
    }

    send(egress_pid, {:stream_start, stream_id, metadata})

    # Start the LLM backend stream — skip tool definitions for managed-loop backends
    tools =
      if state.llm_backend.manages_tool_loop?(),
        do: [],
        else: Cranium.Agent.ToolRouter.tool_definitions()

    opts = [
      system: system,
      max_tokens: Map.get(context, :max_tokens, 8192),
      tools: tools,
      cc_session_id: context[:cc_session_id],
      working_dir: context[:working_dir]
    ]

    result = run_inference(state, egress_pid, stream_id, messages, opts)

    send(egress_pid, {:stream_end, stream_id})

    case result do
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

  defp run_inference(state, egress_pid, stream_id, messages, opts) do
    state = %{state | messages: messages, tool_calls_pending: []}

    case state.llm_backend.stream_chat(messages, opts) do
      {:ok, llm_pid} ->
        ref = Process.monitor(llm_pid)
        result = receive_loop(state, egress_pid, stream_id, llm_pid, ref, opts)
        # Demonitor only if receive_loop didn't already (tool_use path does its own)
        Process.demonitor(ref, [:flush])
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_loop(state, egress_pid, stream_id, llm_pid, ref, opts) do
    receive do
      {:llm_text, text} ->
        send(egress_pid, {:chunk, stream_id, text})
        state = %{state | partial_output: [text | state.partial_output]}
        receive_loop(state, egress_pid, stream_id, llm_pid, ref, opts)

      {:llm_tool_use, tool_call} ->
        if state.llm_backend.manages_tool_loop?() do
          # CC path: only marker tool calls come through, handle inline
          case Cranium.Agent.ToolRouter.route(tool_call) do
            {:marker, marker_type, input} ->
              {_result, marker} = Cranium.Agent.MarkerEmitter.handle(marker_type, input)
              send(egress_pid, {:chunk, stream_id, {:marker, marker}})

            _ ->
              :ok
          end

          receive_loop(state, egress_pid, stream_id, llm_pid, ref, opts)
        else
          # Anthropic path: accumulate for batch execution
          state = %{state | tool_calls_pending: [tool_call | state.tool_calls_pending]}
          receive_loop(state, egress_pid, stream_id, llm_pid, ref, opts)
        end

      {:llm_usage, usage} ->
        merged = merge_usage(state.usage, usage)
        receive_loop(%{state | usage: merged}, egress_pid, stream_id, llm_pid, ref, opts)

      {:cc_tool_use, tool_data} ->
        send(egress_pid, {:chunk, stream_id, {:tool_use, tool_data}})
        receive_loop(state, egress_pid, stream_id, llm_pid, ref, opts)

      {:cc_tool_result, result_data} ->
        send(egress_pid, {:chunk, stream_id, {:tool_result, result_data}})
        receive_loop(state, egress_pid, stream_id, llm_pid, ref, opts)

      {:cc_session, session_id} ->
        receive_loop(%{state | cc_session_id: session_id}, egress_pid, stream_id, llm_pid, ref, opts)

      {:llm_stop, "end_turn"} ->
        {:ok, state}

      {:llm_stop, "tool_use"} ->
        Process.demonitor(ref, [:flush])
        execute_tools_and_continue(state, egress_pid, stream_id, opts)

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
    after
      120_000 ->
        {:error, :timeout}
    end
  end

  defp execute_tools_and_continue(state, egress_pid, stream_id, opts) do
    alias Cranium.Agent.{ToolRouter, ToolExecutor, MarkerEmitter}

    tool_calls = Enum.reverse(state.tool_calls_pending)

    Logger.info("Executing #{length(tool_calls)} tool call(s)")

    # Build assistant content blocks (text + tool_use)
    assistant_content = build_assistant_content(state.partial_output, tool_calls)

    # Execute each tool call and collect results
    tool_results =
      Enum.map(tool_calls, fn tool_call ->
        result =
          case ToolRouter.route(tool_call) do
            {:marker, marker_type, input} ->
              {result_text, marker} = MarkerEmitter.handle(marker_type, input)
              send(egress_pid, {:chunk, stream_id, {:marker, marker}})
              result_text

            {:execute, module, input} ->
              case ToolExecutor.execute(module, input) do
                {:ok, text} -> ToolExecutor.truncate_result(text)
                {:error, reason} -> ~s({"error": "#{inspect(reason)}"})
              end

            {:unknown, name} ->
              ~s({"error": "unknown tool: #{name}"})
          end

        %{role: "user", content: [%{type: "tool_result", tool_use_id: tool_call.id, content: result}]}
      end)

    # Append assistant message + tool results to conversation
    assistant_msg = %{role: "assistant", content: assistant_content}
    updated_messages = state.messages ++ [assistant_msg | tool_results]

    # Clear pending state and re-enter inference
    state = %{state | partial_output: [], tool_calls_pending: []}
    run_inference(state, egress_pid, stream_id, updated_messages, opts)
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

  defp backend_module do
    Application.get_env(:cranium, :backends)[:llm] || Cranium.Backend.LLM.Anthropic
  end
end

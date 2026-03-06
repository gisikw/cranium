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

    # Start the LLM backend stream
    opts = [system: system, max_tokens: Map.get(context, :max_tokens, 8192)]

    result = run_inference(state, egress_pid, stream_id, messages, opts)

    send(egress_pid, {:stream_end, stream_id})

    case result do
      {:ok, final_state} ->
        Logger.info("Inference complete",
          output_length: length(final_state.partial_output),
          input_tokens: final_state.usage[:input_tokens],
          output_tokens: final_state.usage[:output_tokens]
        )

        reply = %{
          stream_id: stream_id,
          status: :complete,
          output: final_state.partial_output |> Enum.reverse() |> Enum.join(),
          usage: final_state.usage
        }

        {:reply, {:ok, reply}, %{final_state | status: :idle, stream_id: nil}}

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
    case state.llm_backend.stream_chat(messages, opts) do
      {:ok, llm_pid} ->
        ref = Process.monitor(llm_pid)
        result = receive_loop(state, egress_pid, stream_id, ref)
        Process.demonitor(ref, [:flush])
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_loop(state, egress_pid, stream_id, ref) do
    receive do
      {:llm_text, text} ->
        send(egress_pid, {:chunk, stream_id, text})
        state = %{state | partial_output: [text | state.partial_output]}
        receive_loop(state, egress_pid, stream_id, ref)

      {:llm_tool_use, _tool_call} ->
        # TODO: Route through ToolRouter → ToolExecutor/MarkerEmitter
        # For now, log and continue (no tool execution in vertical slice)
        Logger.info("Tool call received (not yet implemented)")
        receive_loop(state, egress_pid, stream_id, ref)

      {:llm_usage, usage} ->
        merged = merge_usage(state.usage, usage)
        receive_loop(%{state | usage: merged}, egress_pid, stream_id, ref)

      {:llm_stop, "end_turn"} ->
        {:ok, state}

      {:llm_stop, "tool_use"} ->
        # TODO: Execute tools, append results, re-enter inference
        Logger.info("Tool use stop (not yet implemented)")
        {:ok, state}

      {:llm_stop, {:error, _status, _body} = error} ->
        {:error, error}

      {:llm_stop, {:error, _reason} = error} ->
        {:error, error}

      {:llm_stop, other} ->
        Logger.warning("Unexpected stop reason", reason: inspect(other))
        {:ok, state}

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

  defp merge_usage(existing, new) do
    %{
      input_tokens: (existing[:input_tokens] || 0) + (new[:input_tokens] || 0),
      output_tokens: (existing[:output_tokens] || 0) + (new[:output_tokens] || 0)
    }
  end

  # --- Private ---

  defp backend_module do
    Application.get_env(:cranium, :backends)[:llm] || Cranium.Backend.LLM.Anthropic
  end
end

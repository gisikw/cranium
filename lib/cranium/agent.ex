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
    partial_output: []
  ]

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          epoch_pid: pid() | nil,
          stream_id: String.t() | nil,
          llm_backend: module(),
          status: :idle | :inferring | :tool_use | :cancelled,
          messages: list(),
          tool_calls_pending: list(),
          partial_output: list()
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
  def handle_call({:infer, context, _egress_pid}, _from, state) do
    stream_id = Cranium.Stage.new_stream_id()

    state = %{
      state
      | status: :inferring,
        stream_id: stream_id,
        messages: context[:messages] || []
    }

    # TODO: Implement the inference loop
    # 1. Call llm_backend.stream_chat(messages, opts)
    # 2. Process SSE chunks
    # 3. Handle tool calls via Harness
    # 4. Forward text chunks to egress_pid
    # 5. Loop on tool_use, complete on end_turn

    Logger.info("Inference complete")
    {:reply, {:ok, %{stream_id: stream_id, status: :complete}}, %{state | status: :idle}}
  end

  @impl true
  def handle_cast(:cancel, state) do
    Logger.info("Agent cancelled")
    # TODO: Kill LLM backend stream, capture partial output
    {:noreply, %{state | status: :cancelled}}
  end

  # Handle streaming chunks from LLM backend
  @impl true
  def handle_info({:llm_chunk, _chunk}, %{status: :cancelled} = state) do
    # Discard chunks after cancel
    {:noreply, state}
  end

  def handle_info({:llm_chunk, chunk}, state) do
    # TODO: Parse chunk, detect tool_use vs text, route accordingly
    state = %{state | partial_output: [chunk | state.partial_output]}
    {:noreply, state}
  end

  def handle_info({:llm_done, _reason}, state) do
    {:noreply, %{state | status: :idle}}
  end

  # --- Private ---

  defp backend_module do
    Application.get_env(:cranium, :backends)[:llm] || Cranium.Backend.LLM.Anthropic
  end
end

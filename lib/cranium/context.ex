defmodule Cranium.Context do
  @moduledoc """
  Context assembly stage.

  Takes a normalized message from Ingress and builds the complete inference
  context: system prompt, turn-level injections, and conversation history.
  Decomposes into four steps:

  - `Router` — map conversation to working directory, determine project context
  - `PromptBuilder` — assemble system prompt (identity + handoff + landscape)
  - `TurnInjector` — add per-turn context (time gaps, saturation, interrupted
    context, resume breadcrumbs)
  - `HistoryManager` — retrieve and format conversation history

  ## Output

  Produces an inference-ready payload:

      %{
        system: String.t(),           # assembled system prompt
        messages: [message()],        # conversation history + current turn
        metadata: %{                  # routing and state info
          conversation_id: String.t(),
          working_dir: String.t(),
          epoch_id: String.t(),
          ...
        }
      }

  ## Design Note

  Context assembly is the most "pure function" stage. Each step takes data
  in and returns data out, with Store reads as the only side effect. The
  GenServer exists for uniformity with other stages and to support future
  streaming (e.g., streaming history retrieval from a large conversation).
  """

  use GenServer

  require Logger

  defstruct buffers: %{}

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Assemble the full inference context from a normalized message.
  """
  @spec process(map(), map()) :: {:ok, map()} | {:error, term()}
  def process(message, context) do
    with {:ok, routed} <- Cranium.Context.Router.process(message, context),
         {:ok, prompted} <- Cranium.Context.PromptBuilder.process(routed, context),
         {:ok, injected} <- Cranium.Context.TurnInjector.process(prompted, context),
         {:ok, with_history} <- Cranium.Context.HistoryManager.process(injected, context) do
      {:ok, with_history}
    end
  end

  # --- GenServer Implementation ---

  @impl GenServer
  def init(_opts) do
    Logger.info("Context stage started", stage: :context)
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call({:process, message, context}, _from, state) do
    result = process(message, context)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:stream_start, stream_id, metadata}, state) do
    Logger.debug("Stream started", stage: :context, stream_id: stream_id)
    buffers = Cranium.Stage.init_stream(state.buffers, stream_id, metadata)
    {:noreply, %{state | buffers: buffers}}
  end

  @impl GenServer
  def handle_info({:chunk, stream_id, chunk}, state) do
    buffers = Cranium.Stage.buffer_chunk(state.buffers, stream_id, chunk)
    {:noreply, %{state | buffers: buffers}}
  end

  @impl GenServer
  def handle_info({:stream_end, stream_id}, state) do
    {_data, _metadata, buffers} = Cranium.Stage.flush_buffer(state.buffers, stream_id)
    # TODO: Process buffered streaming context
    {:noreply, %{state | buffers: buffers}}
  end
end

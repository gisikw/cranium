defmodule Cranium.Egress do
  @moduledoc """
  Output processing stage.

  Transforms streaming agent output into deliverable formats. This stage
  is streaming-native — it receives chunks from the Agent and forwards
  processed output to transports.

  Decomposes into two steps:

  - `Chunker` — segments streaming text into deliverable units. In voice
    mode, chunks at sentence boundaries for natural TTS pacing. In text
    mode, chunks at paragraph breaks for readable streaming.
  - `Synthesizer` — routes text chunks through TTS backend when in voice
    mode. Pass-through in text mode.

  ## Mode

  Egress operates in one of two modes, set per-session:

  - `:text` — chunks are delivered as text to the transport
  - `:voice` — chunks are synthesized to audio, then delivered

  The model doesn't know which mode it's in. Mode is a session-level flag
  that the transport can toggle.

  ## Markers

  SCTE markers from the Agent pass through Egress without modification.
  They're positional cues for the transport — "show this image here,"
  "display this code block here." The transport decides how to render them.
  """

  use GenServer

  require Logger

  defstruct buffers: %{}, mode: :text

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Process a complete output through chunking and optional synthesis.
  """
  @spec process(term(), map()) :: {:ok, [term()]}
  def process(output, context) do
    mode = Map.get(context, :mode, :text)

    with {:ok, chunks} <- Cranium.Egress.Chunker.process(output, context) do
      if mode == :voice do
        Cranium.Egress.Synthesizer.process(chunks, context)
      else
        {:ok, chunks}
      end
    end
  end

  @doc false
  def handle_chunk(stream_id, chunk, state) do
    # Forward text chunks through chunker immediately
    case Cranium.Egress.Chunker.process_chunk(chunk) do
      {:emit, processed} ->
        {:forward, processed, state}

      :accumulate ->
        {:buffer,
         Cranium.Stage.buffer_chunk(state.buffers, stream_id, chunk)
         |> then(&%{state | buffers: &1})}
    end
  end

  @doc false
  def handle_stream_end(stream_id, state) do
    {data, buffers} = Cranium.Stage.flush_buffer(state.buffers, stream_id)
    # Flush any remaining buffered text as a final chunk
    {:ok, data, %{state | buffers: buffers}}
  end

  # --- GenServer Implementation ---

  @impl GenServer
  def init(_opts) do
    Logger.info("Egress stage started", stage: :egress)
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call({:process, output, context}, _from, state) do
    result = process(output, context)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:chunk, stream_id, chunk}, state) do
    case handle_chunk(stream_id, chunk, state) do
      {:forward, data, new_state} ->
        # TODO: Forward to transport
        Logger.debug("Forwarding chunk", stage: :egress, data_size: byte_size(data))
        {:noreply, new_state}

      {:buffer, new_state} ->
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({:stream_end, stream_id}, state) do
    {:ok, _data, new_state} = handle_stream_end(stream_id, state)
    {:noreply, new_state}
  end
end

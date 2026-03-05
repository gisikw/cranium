defmodule Cranium.Ingress do
  @moduledoc """
  Input processing stage.

  Receives raw input from transports and produces a normalized message
  ready for context assembly. Decomposes into four steps:

  - `Deduplicator` — reject duplicate events
  - `Transcriber` — audio → text via STT backend
  - `ImageProcessor` — download/store images, produce references
  - `CommandDetector` — detect control commands (!clear, !cancel),
    emit pipeline signals

  ## Message Flow

  Transport delivers a raw event (text, audio, image, or mixed). Ingress
  runs it through each step in order. If CommandDetector identifies a
  control command, it returns `{:command, command}` instead of a
  normalized message — the Session handles commands separately from
  the inference pipeline.

  ## Streaming

  Ingress does not currently support incremental streaming — input must
  be fully received before processing. However, when Voxtral Mini
  Realtime replaces Whisper, the Transcriber will accept streaming audio
  and emit text chunks. The Ingress GenServer is wired for this via the
  Stage behaviour.
  """

  use GenServer

  require Logger

  defstruct buffers: %{}

  @type raw_event :: %{
          type: :text | :audio | :image | :mixed,
          body: String.t() | nil,
          audio: binary() | nil,
          image: binary() | nil,
          event_id: String.t(),
          room_id: String.t(),
          sender: String.t(),
          timestamp: DateTime.t()
        }

  @type normalized :: %{
          text: String.t(),
          attachments: [map()],
          event_id: String.t(),
          room_id: String.t(),
          sender: String.t(),
          timestamp: DateTime.t()
        }

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Process a raw event into a normalized message or command.
  """
  @spec process(raw_event(), map()) ::
          {:ok, normalized()} | {:command, atom(), map()} | {:error, term()}
  def process(event, context) do
    GenServer.call(__MODULE__, {:process, event, context})
  end

  @doc false
  def do_process(event, context) do
    with {:ok, event} <- Cranium.Ingress.Deduplicator.check(event, context),
         {:ok, event} <- Cranium.Ingress.Transcriber.process(event, context),
         {:ok, event} <- Cranium.Ingress.ImageProcessor.process(event, context) do
      Cranium.Ingress.CommandDetector.process(event, context)
    end
  end

  # --- GenServer Implementation ---

  @impl GenServer
  def init(_opts) do
    Logger.info("Ingress stage started", stage: :ingress)
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call({:process, event, context}, _from, state) do
    result = do_process(event, context)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:chunk, stream_id, chunk}, state) do
    buffers = Cranium.Stage.buffer_chunk(state.buffers, stream_id, chunk)
    {:noreply, %{state | buffers: buffers}}
  end

  @impl GenServer
  def handle_info({:stream_end, stream_id}, state) do
    {_data, buffers} = Cranium.Stage.flush_buffer(state.buffers, stream_id)
    # TODO: Process buffered streaming input
    {:noreply, %{state | buffers: buffers}}
  end
end

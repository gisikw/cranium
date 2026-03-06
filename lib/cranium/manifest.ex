defmodule Cranium.Manifest do
  @moduledoc """
  Tracks segment manifests for active streams.

  A manifest is a growing playlist of heterogeneous content blocks (utterances
  and cues) that clients poll and consume. Each stream gets its own manifest
  initialized by Egress on stream start, populated as chunks arrive, and
  completed when the Agent finishes.

  Manifests are ephemeral — they live only while a stream is active plus a
  short TTL after completion.
  """

  use GenServer

  require Logger

  defstruct streams: %{}

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Initialize a new stream manifest."
  def init_stream(stream_id, conversation_id, name \\ __MODULE__) do
    GenServer.call(name, {:init_stream, stream_id, conversation_id})
  end

  @doc "Add an utterance segment with text content. Audio URL is advertised but served lazily."
  def add_utterance(stream_id, index, text, name \\ __MODULE__) do
    GenServer.call(name, {:add_utterance, stream_id, index, text})
  end

  @doc "Add a cue segment (SCTE-style marker from a tool call)."
  def add_cue(stream_id, index, cue_type, data, name \\ __MODULE__) do
    GenServer.call(name, {:add_cue, stream_id, index, cue_type, data})
  end

  @doc "Mark a stream as complete."
  def complete(stream_id, name \\ __MODULE__) do
    GenServer.call(name, {:complete, stream_id})
  end

  @doc "Get the manifest for a stream. Returns {:ok, manifest} or :not_found."
  def get(stream_id, name \\ __MODULE__) do
    GenServer.call(name, {:get, stream_id})
  end

  @doc "Get text content for a specific segment. Used by the HTTP transport."
  def get_segment_text(stream_id, index, name \\ __MODULE__) do
    GenServer.call(name, {:get_segment_text, stream_id, index})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Logger.info("Manifest registry started")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:init_stream, stream_id, conversation_id}, _from, state) do
    manifest = %{
      stream_id: stream_id,
      conversation_id: conversation_id,
      status: :streaming,
      segments: []
    }

    streams = Map.put(state.streams, stream_id, manifest)
    {:reply, :ok, %{state | streams: streams}}
  end

  @impl true
  def handle_call({:add_utterance, stream_id, index, text}, _from, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, manifest} ->
        segment = %{
          index: index,
          type: :utterance,
          renditions: %{
            text: %{mime: "text/plain", content: text},
            audio: %{mime: "audio/mp3"}
          }
        }

        manifest = %{manifest | segments: manifest.segments ++ [segment]}
        streams = Map.put(state.streams, stream_id, manifest)
        {:reply, :ok, %{state | streams: streams}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:add_cue, stream_id, index, cue_type, data}, _from, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, manifest} ->
        segment = %{
          index: index,
          type: :cue,
          cue_type: cue_type,
          data: data
        }

        manifest = %{manifest | segments: manifest.segments ++ [segment]}
        streams = Map.put(state.streams, stream_id, manifest)
        {:reply, :ok, %{state | streams: streams}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:complete, stream_id}, _from, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, manifest} ->
        manifest = %{manifest | status: :complete}
        streams = Map.put(state.streams, stream_id, manifest)
        {:reply, :ok, %{state | streams: streams}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get, stream_id}, _from, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, manifest} ->
        {:reply, {:ok, to_json_manifest(manifest)}, state}

      :error ->
        {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_call({:get_segment_text, stream_id, index}, _from, state) do
    reply =
      with {:ok, manifest} <- Map.fetch(state.streams, stream_id),
           segment when not is_nil(segment) <- Enum.find(manifest.segments, &(&1.index == index)),
           %{type: :utterance, renditions: %{text: %{content: content}}} <- segment do
        {:ok, content}
      else
        _ -> :not_found
      end

    {:reply, reply, state}
  end

  # --- Private ---

  defp to_json_manifest(manifest) do
    %{
      "stream_id" => manifest.stream_id,
      "status" => to_string(manifest.status),
      "segments" => Enum.map(manifest.segments, &to_json_segment(&1, manifest.stream_id))
    }
  end

  defp to_json_segment(%{type: :utterance} = seg, stream_id) do
    %{
      "index" => seg.index,
      "type" => "utterance",
      "renditions" => %{
        "text" => %{
          "url" => "/v1/streams/#{stream_id}/segments/#{seg.index}/text",
          "mime" => seg.renditions.text.mime
        },
        "audio" => %{
          "url" => "/v1/streams/#{stream_id}/segments/#{seg.index}/audio",
          "mime" => seg.renditions.audio.mime
        }
      }
    }
  end

  defp to_json_segment(%{type: :cue} = seg, _stream_id) do
    %{
      "index" => seg.index,
      "type" => "cue",
      "cue_type" => to_string(seg.cue_type),
      "data" => seg.data
    }
  end
end

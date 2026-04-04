defmodule Cranium.Transport.Manifest do
  @moduledoc """
  Tracks segment manifests for active streams.

  A manifest is a growing playlist of heterogeneous content blocks (utterances
  and cues) that clients poll and consume. Each stream gets its own manifest
  initialized on stream start, populated as chunks arrive, and completed when
  the Agent finishes.

  Manifests are ephemeral — they live only while a stream is active plus a
  short TTL after completion.
  """

  use GenServer

  require Logger

  use TypedStruct

  typedstruct do
    field :streams, map(), default: %{}
  end

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Initialize a new stream manifest.

  Options:
  - `:disposition` — list of rendition types the client wants (default `["text"]`).
    Controls which renditions are advertised in the JSON manifest.
  - `:name` — GenServer name (default `__MODULE__`, used by tests).
  """
  @spec init_stream(String.t(), String.t(), keyword()) :: :ok
  def init_stream(stream_id, conversation_id, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    disposition = Keyword.get(opts, :disposition, ["text"])
    GenServer.call(name, {:init_stream, stream_id, conversation_id, disposition})
  end

  @doc "Add an utterance segment with text content. Audio URL is advertised but served lazily."
  @spec add_utterance(String.t(), non_neg_integer(), String.t(), atom()) ::
          :ok | {:error, :not_found}
  def add_utterance(stream_id, index, text, name \\ __MODULE__) do
    GenServer.call(name, {:add_utterance, stream_id, index, text})
  end

  @doc "Add a cue segment (SCTE-style marker from a tool call)."
  @spec add_cue(String.t(), non_neg_integer(), atom(), term(), atom()) ::
          :ok | {:error, :not_found}
  def add_cue(stream_id, index, cue_type, data, name \\ __MODULE__) do
    GenServer.call(name, {:add_cue, stream_id, index, cue_type, data})
  end

  @doc "Mark a stream as complete."
  @spec complete(String.t(), atom()) :: :ok | {:error, :not_found}
  def complete(stream_id, name \\ __MODULE__) do
    GenServer.call(name, {:complete, stream_id})
  end

  @doc "Mark a stream as cancelled. Partial segments may exist."
  @spec cancel(String.t(), atom()) :: :ok | {:error, :not_found}
  def cancel(stream_id, name \\ __MODULE__) do
    GenServer.call(name, {:cancel, stream_id})
  end

  @doc "Attach metadata (e.g. saturation, usage) to a stream manifest."
  @spec set_metadata(String.t(), map(), atom()) :: :ok | {:error, :not_found}
  def set_metadata(stream_id, metadata, name \\ __MODULE__) when is_map(metadata) do
    GenServer.call(name, {:set_metadata, stream_id, metadata})
  end

  @doc "Get the manifest for a stream. Returns {:ok, manifest} or :not_found."
  @spec get(String.t(), atom()) :: {:ok, map()} | :not_found
  def get(stream_id, name \\ __MODULE__) do
    GenServer.call(name, {:get, stream_id})
  end

  @doc "Get text content for a specific segment. Used by the HTTP transport."
  @spec get_segment_text(String.t(), non_neg_integer(), atom()) :: {:ok, String.t()} | :not_found
  def get_segment_text(stream_id, index, name \\ __MODULE__) do
    GenServer.call(name, {:get_segment_text, stream_id, index})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Cranium.Events.subscribe()
    Logger.info("Manifest started")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:init_stream, stream_id, conversation_id, disposition}, _from, state) do
    manifest = %{
      stream_id: stream_id,
      conversation_id: conversation_id,
      disposition: disposition,
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
  def handle_call({:set_metadata, stream_id, metadata}, _from, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, manifest} ->
        manifest = Map.update(manifest, :metadata, metadata, &Map.merge(&1, metadata))
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
  def handle_call({:cancel, stream_id}, _from, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, manifest} ->
        manifest = %{manifest | status: :cancelled}
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

  # --- Event Handlers ---

  @impl true
  def handle_info({:segment_ready, stream_id, index, %{type: :utterance, text: text}}, state) do
    state = append_segment(state, stream_id, %{
      index: index,
      type: :utterance,
      renditions: %{
        text: %{mime: "text/plain", content: text},
        audio: %{mime: "audio/mp3"}
      }
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:segment_ready, stream_id, index, %{type: :cue, cue_type: cue_type, data: data}}, state) do
    state = append_segment(state, stream_id, %{
      index: index,
      type: :cue,
      cue_type: cue_type,
      data: data
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:pass_complete, _cid, stream_id, %{reason: :complete} = meta}, state) do
    metadata =
      %{}
      |> maybe_put("saturation", meta[:saturation] && Float.round(meta.saturation, 3))
      |> maybe_put("turn_count", meta[:turn_count])

    state =
      update_stream(state, stream_id, fn manifest ->
        manifest = %{manifest | status: :complete}

        if map_size(metadata) > 0 do
          Map.update(manifest, :metadata, metadata, &Map.merge(&1, metadata))
        else
          manifest
        end
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:pass_complete, _cid, stream_id, %{reason: :cancelled}}, state) do
    state = update_stream(state, stream_id, &%{&1 | status: :cancelled})
    {:noreply, state}
  end

  @impl true
  def handle_info({:pass_complete, _cid, stream_id, %{reason: :error}}, state) do
    state = update_stream(state, stream_id, &%{&1 | status: :complete})
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp update_stream(state, stream_id, fun) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, manifest} ->
        %{state | streams: Map.put(state.streams, stream_id, fun.(manifest))}

      :error ->
        state
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp append_segment(state, stream_id, segment) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, manifest} ->
        manifest = %{manifest | segments: manifest.segments ++ [segment]}
        %{state | streams: Map.put(state.streams, stream_id, manifest)}

      :error ->
        state
    end
  end

  defp to_json_manifest(manifest) do
    disposition = Map.get(manifest, :disposition, ["text"])

    base = %{
      "stream_id" => manifest.stream_id,
      "status" => to_string(manifest.status),
      "segments" =>
        Enum.map(manifest.segments, &to_json_segment(&1, manifest.stream_id, disposition))
    }

    case Map.get(manifest, :metadata) do
      nil -> base
      meta -> Map.put(base, "metadata", meta)
    end
  end

  defp to_json_segment(%{type: :utterance} = seg, stream_id, disposition) do
    renditions =
      %{}
      |> maybe_put_rendition("text", disposition, %{
        "url" => "/v1/streams/#{stream_id}/segments/#{seg.index}/text",
        "mime" => seg.renditions.text.mime
      })
      |> maybe_put_rendition("audio", disposition, %{
        "url" => "/v1/streams/#{stream_id}/segments/#{seg.index}/audio",
        "mime" => seg.renditions.audio.mime
      })

    %{
      "index" => seg.index,
      "type" => "utterance",
      "renditions" => renditions
    }
  end

  defp to_json_segment(%{type: :cue} = seg, _stream_id, _disposition) do
    %{
      "index" => seg.index,
      "type" => "cue",
      "cue_type" => to_string(seg.cue_type),
      "data" => seg.data
    }
  end

  defp maybe_put_rendition(renditions, type, disposition, value) do
    if type in disposition, do: Map.put(renditions, type, value), else: renditions
  end
end

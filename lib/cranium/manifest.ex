defmodule Cranium.Manifest do
  @moduledoc """
  Tracks segment manifests for active streams.

  A manifest is a growing playlist of heterogeneous content blocks (utterances
  and cues) that clients poll and consume. Each stream gets its own manifest
  initialized by Egress on stream start, populated as chunks arrive, and
  completed when the Agent finishes.

  Manifests are ephemeral — they live only while a stream is active plus a
  short TTL after completion.

  ## Pipeline Timing

  Each manifest carries a `timing` map of monotonic timestamps appended by
  pipeline stages via `stamp/3`. Segment-level timing is stored per-segment
  via `stamp_segment/4`. Wall-clock ISO8601 strings are derived at
  serialization time.
  """

  use GenServer

  require Logger

  defstruct streams: %{}

  # --- Public API ---

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
  def init_stream(stream_id, conversation_id, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    disposition = Keyword.get(opts, :disposition, ["text"])
    GenServer.call(name, {:init_stream, stream_id, conversation_id, disposition})
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

  @doc "Mark a stream as cancelled. Partial segments may exist."
  def cancel(stream_id, name \\ __MODULE__) do
    GenServer.call(name, {:cancel, stream_id})
  end

  @doc "Attach metadata (e.g. saturation, usage) to a stream manifest."
  def set_metadata(stream_id, metadata, name \\ __MODULE__) when is_map(metadata) do
    GenServer.call(name, {:set_metadata, stream_id, metadata})
  end

  @doc """
  Record a pipeline timing milestone. Stores monotonic time internally;
  wall-clock ISO8601 is derived at serialization.
  """
  def stamp(stream_id, milestone, name \\ __MODULE__) when is_atom(milestone) do
    GenServer.cast(name, {:stamp, stream_id, milestone, mono_now()})
  end

  @doc """
  Record a per-segment timing milestone.
  """
  def stamp_segment(stream_id, index, milestone, name \\ __MODULE__) when is_atom(milestone) do
    GenServer.cast(name, {:stamp_segment, stream_id, index, milestone, mono_now()})
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
  def handle_call({:init_stream, stream_id, conversation_id, disposition}, _from, state) do
    manifest = %{
      stream_id: stream_id,
      conversation_id: conversation_id,
      disposition: disposition,
      status: :streaming,
      segments: [],
      timing: %{},
      wall_origin: DateTime.utc_now(),
      mono_origin: mono_now()
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
          timing: %{emitted: mono_now()},
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
        manifest = put_timing(manifest, :manifest_complete, mono_now())
        log_pipeline_timing(manifest)
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
        manifest = put_timing(manifest, :manifest_complete, mono_now())
        log_pipeline_timing(manifest)
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

  # --- Cast handlers for timing (fire-and-forget from callers) ---

  @impl true
  def handle_cast({:stamp, stream_id, milestone, mono}, state) do
    state = update_stream(state, stream_id, &put_timing(&1, milestone, mono))
    {:noreply, state}
  end

  @impl true
  def handle_cast({:stamp_segment, stream_id, index, milestone, mono}, state) do
    state =
      update_stream(state, stream_id, fn manifest ->
        segments =
          Enum.map(manifest.segments, fn
            %{index: ^index} = seg ->
              timing = Map.get(seg, :timing, %{})
              %{seg | timing: Map.put(timing, milestone, mono)}

            seg ->
              seg
          end)

        %{manifest | segments: segments}
      end)

    {:noreply, state}
  end

  # --- Private ---

  defp update_stream(state, stream_id, fun) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, manifest} ->
        streams = Map.put(state.streams, stream_id, fun.(manifest))
        %{state | streams: streams}

      :error ->
        state
    end
  end

  defp put_timing(manifest, milestone, mono) do
    %{manifest | timing: Map.put(manifest.timing, milestone, mono)}
  end

  defp mono_now, do: System.monotonic_time(:millisecond)

  defp log_pipeline_timing(manifest) do
    t = manifest.timing
    origin = manifest.mono_origin

    # Compute deltas between consecutive milestones
    deltas =
      [:submitted, :context_assembled, :inference_start, :first_token, :stream_end, :manifest_complete]
      |> Enum.map(fn m -> {m, Map.get(t, m)} end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    total = offset(t, :manifest_complete, origin)

    fields =
      deltas
      |> Enum.map(fn {m, mono} -> "#{m}=#{mono - origin}ms" end)
      |> Enum.join(" ")

    Logger.info(
      "Pipeline timing: stream=#{manifest.stream_id} conversation=#{manifest.conversation_id} status=#{manifest.status} #{fields} total=#{total}ms",
      stage: :manifest
    )
  end

  defp offset(timing, milestone, origin) do
    case Map.get(timing, milestone) do
      nil -> 0
      mono -> mono - origin
    end
  end

  defp to_json_manifest(manifest) do
    disposition = Map.get(manifest, :disposition, ["text"])
    origin_wall = manifest.wall_origin
    origin_mono = manifest.mono_origin

    base = %{
      "stream_id" => manifest.stream_id,
      "status" => to_string(manifest.status),
      "segments" => Enum.map(manifest.segments, &to_json_segment(&1, manifest.stream_id, disposition, origin_wall, origin_mono)),
      "timing" => timing_to_json(manifest.timing, origin_wall, origin_mono)
    }

    case Map.get(manifest, :metadata) do
      nil -> base
      meta -> Map.put(base, "metadata", meta)
    end
  end

  defp to_json_segment(%{type: :utterance} = seg, stream_id, disposition, origin_wall, origin_mono) do
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

    base = %{
      "index" => seg.index,
      "type" => "utterance",
      "renditions" => renditions
    }

    case Map.get(seg, :timing) do
      nil -> base
      timing when map_size(timing) == 0 -> base
      timing -> Map.put(base, "timing", timing_to_json(timing, origin_wall, origin_mono))
    end
  end

  defp to_json_segment(%{type: :cue} = seg, _stream_id, _disposition, _origin_wall, _origin_mono) do
    %{
      "index" => seg.index,
      "type" => "cue",
      "cue_type" => to_string(seg.cue_type),
      "data" => seg.data
    }
  end

  defp timing_to_json(timing, origin_wall, origin_mono) do
    Map.new(timing, fn {milestone, mono} ->
      offset_ms = mono - origin_mono
      wall = DateTime.add(origin_wall, offset_ms, :millisecond)

      {to_string(milestone), %{
        "wall" => DateTime.to_iso8601(wall),
        "offset_ms" => offset_ms
      }}
    end)
  end

  defp maybe_put_rendition(renditions, type, disposition, value) do
    if type in disposition, do: Map.put(renditions, type, value), else: renditions
  end
end

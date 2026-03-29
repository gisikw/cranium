defmodule Cranium.TTS.Warmer do
  @moduledoc """
  Sequential TTS warm queue.

  Processes TTS synthesis requests one at a time to avoid overwhelming a
  single-GPU backend with concurrent requests. Runs off the Egress GenServer
  so it doesn't block chunk processing.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(String.t(), non_neg_integer(), String.t(), atom()) :: :ok
  def enqueue(stream_id, index, text, name \\ __MODULE__) do
    Cranium.Manifest.stamp_segment(stream_id, index, :warm_enqueued)
    GenServer.cast(name, {:enqueue, stream_id, index, text})
  end

  @impl true
  def init(_opts) do
    Logger.info("TTS warmer started")
    {:ok, %{queue: :queue.new(), busy: false}}
  end

  @impl true
  def handle_cast({:enqueue, stream_id, index, text}, state) do
    state = %{state | queue: :queue.in({stream_id, index, text}, state.queue)}

    if state.busy do
      {:noreply, state}
    else
      {:noreply, process_next(state)}
    end
  end

  @impl true
  def handle_info({:warm_done, stream_id, index, result, started_at}, state) do
    Cranium.Manifest.stamp_segment(stream_id, index, :warm_complete)
    synthesis_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, audio} ->
        Cranium.TTS.Cache.put(stream_id, index, audio)

        Logger.info(
          "Segment warm complete: stream=#{stream_id} segment=#{index} synthesis=#{synthesis_ms}ms bytes=#{byte_size(audio)}",
          stage: :tts
        )

      {:error, reason} ->
        Cranium.TTS.Cache.put(stream_id, index, :error)

        Logger.error(
          "TTS warm failed: stream=#{stream_id} segment=#{index} synthesis=#{synthesis_ms}ms reason=#{inspect(reason)}",
          stage: :tts
        )
    end

    {:noreply, process_next(%{state | busy: false})}
  end

  defp process_next(state) do
    case :queue.out(state.queue) do
      {{:value, {stream_id, index, text}}, queue} ->
        warmer = self()
        Cranium.Manifest.stamp_segment(stream_id, index, :warm_started)
        started_at = System.monotonic_time(:millisecond)

        Task.start(fn ->
          backend =
            Application.get_env(:cranium, :backends)[:tts] || Cranium.Backend.TTS.ExoVoice

          result = backend.synthesize(text, [])
          send(warmer, {:warm_done, stream_id, index, result, started_at})
        end)

        %{state | queue: queue, busy: true}

      {:empty, _queue} ->
        state
    end
  end
end

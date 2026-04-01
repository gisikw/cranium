defmodule Cranium.Media.Transcoder do
  require Logger
  use GenServer

  alias Cranium.Messages.{Segment, Transcription}
  alias Cranium.Media.Transcoder.Transcriber

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    stt_cache = :ets.new(:stt_cache, [:set, :read_concurrency])
    schedule_sweep()
    Cranium.Events.subscribe()
    {:ok, %{stt_cache: stt_cache}}
  end

  @impl true
  def handle_info(:sweep, %{stt_cache: stt_cache} = state) do
    cutoff = System.monotonic_time(:second) - 300
    :ets.select_delete(stt_cache, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info({:segment_received, %Segment{direction: :inbound} = seg}, %{stt_cache: stt_cache} = state) do
    cache_key = :erlang.phash2(seg.audio)
    case :ets.lookup(stt_cache, cache_key) do
      [{_, result, _}] -> emit_transcription(result, seg)
      [] ->
        case Transcriber.process(seg.audio) do
          {:ok, result} ->
            :ets.insert(stt_cache, {cache_key, result, System.monotonic_time(:second)})
            emit_transcription(result, seg)
          {:error, reason} ->
            Logger.error("Transcription failed: #{inspect(reason)}")
            emit_transcription_failure(reason, seg)
        end
    end
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.minutes(1))

  defp emit_transcription(text, %Segment{conversation_id: cid}) do
    Cranium.Events.broadcast({:transcription_complete, %Transcription{text: text, conversation_id: cid}})
  end

  defp emit_transcription_failure(reason, %Segment{conversation_id: cid}) do
    Cranium.Events.broadcast({:transcription_failed, %Transcription{failure: reason, conversation_id: cid}})
  end
end

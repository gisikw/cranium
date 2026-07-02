defmodule Cranium.Media.TakeCollector do
  @moduledoc """
  Assembles transcription results into complete takes.

  Subscribes to transcription_complete events from Transcoder and take_sealed
  events from Transport. For single-segment transcriptions (seq: nil), emits
  take_complete immediately. For multi-segment takes, buffers transcription
  chunks by take_id and emits take_complete when sealed and all chunks received.

  Domain: Media — this actor owns the "raw transcriptions → assembled text"
  concern. Downstream, TurnAssembler (Inference) correlates take_complete
  events with PassHeaders for dispatch.
  """

  use GenServer
  require Logger

  alias Cranium.Messages.{Transcription, TakeComplete}

  @stale_timeout_ms :timer.minutes(20)
  @sweep_interval_ms :timer.minutes(1)

  defmodule TakeState do
    @moduledoc false
    defstruct chunks: %{},
              sealed: false,
              last_seq: nil,
              inserted_at: nil
  end

  defmodule State do
    @moduledoc false
    defstruct takes: %{}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Cranium.Events.subscribe()
    schedule_sweep()
    {:ok, %State{}}
  end

  # Single-segment transcription (seq: nil) → immediate take_complete
  @impl true
  def handle_info(
        {:transcription_complete, %Transcription{seq: nil, take_id: take_id, text: text}},
        state
      )
      when not is_nil(take_id) and not is_nil(text) do
    Logger.info("TakeCollector: single-segment complete take=#{take_id}")
    emit_take_complete(take_id, text)
    {:noreply, state}
  end

  # Multi-segment transcription (seq != nil) → buffer chunk, check completeness
  @impl true
  def handle_info(
        {:transcription_complete, %Transcription{seq: seq, take_id: take_id, text: text}},
        state
      )
      when not is_nil(seq) and not is_nil(take_id) and not is_nil(text) do
    Logger.debug("TakeCollector: chunk transcribed take=#{take_id} seq=#{seq}")

    take_state =
      Map.get(state.takes, take_id, %TakeState{
        inserted_at: System.monotonic_time(:millisecond)
      })

    take_state = %{take_state | chunks: Map.put(take_state.chunks, seq, text)}
    state = %{state | takes: Map.put(state.takes, take_id, take_state)}
    {:noreply, maybe_complete(state, take_id)}
  end

  # Take sealed → record seal info, check completeness
  @impl true
  def handle_info({:take_sealed, take_id, last_seq}, state) do
    Logger.debug("TakeCollector: sealed take=#{take_id} last_seq=#{last_seq}")

    take_state =
      Map.get(state.takes, take_id, %TakeState{
        inserted_at: System.monotonic_time(:millisecond)
      })

    take_state = %{take_state | sealed: true, last_seq: last_seq}
    state = %{state | takes: Map.put(state.takes, take_id, take_state)}
    {:noreply, maybe_complete(state, take_id)}
  end

  # Transcription failure (single segment)
  @impl true
  def handle_info(
        {:transcription_failed, %Transcription{seq: nil, take_id: take_id}},
        state
      ) do
    Logger.warning("TakeCollector: single-segment transcription failed take=#{take_id}")
    {:noreply, state}
  end

  # Transcription failure (chunked) — substitute placeholder so take can still complete
  @impl true
  def handle_info(
        {:transcription_failed, %Transcription{seq: seq, take_id: take_id}},
        state
      )
      when not is_nil(seq) do
    Logger.warning(
      "TakeCollector: chunk transcription failed take=#{take_id} seq=#{seq}, substituting placeholder"
    )

    take_state =
      Map.get(state.takes, take_id, %TakeState{
        inserted_at: System.monotonic_time(:millisecond)
      })

    take_state = %{
      take_state
      | chunks: Map.put(take_state.chunks, seq, "[transcribed segment missing]")
    }

    state = %{state | takes: Map.put(state.takes, take_id, take_state)}
    {:noreply, maybe_complete(state, take_id)}
  end

  # Sweep stale entries
  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @stale_timeout_ms
    stale = for {id, %TakeState{inserted_at: t}} <- state.takes, t < cutoff, do: id

    if stale != [] do
      Logger.warning("TakeCollector: sweeping #{length(stale)} stale takes")
    end

    schedule_sweep()
    {:noreply, %{state | takes: Map.drop(state.takes, stale)}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp maybe_complete(state, take_id) do
    case Map.get(state.takes, take_id) do
      %TakeState{sealed: true, last_seq: last_seq, chunks: chunks}
      when not is_nil(last_seq) ->
        expected = MapSet.new(0..last_seq)
        received = MapSet.new(Map.keys(chunks))

        if MapSet.equal?(expected, received) do
          text =
            chunks
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map(&elem(&1, 1))
            |> Enum.join()

          Logger.info("TakeCollector: take complete take=#{take_id} chunks=#{last_seq + 1}")

          emit_take_complete(take_id, text)
          %{state | takes: Map.delete(state.takes, take_id)}
        else
          state
        end

      _ ->
        state
    end
  end

  defp emit_take_complete(take_id, text) do
    Cranium.Events.broadcast({:take_complete, %TakeComplete{take_id: take_id, text: text}})
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end

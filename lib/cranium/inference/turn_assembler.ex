defmodule Cranium.Inference.TurnAssembler do
  @moduledoc """
  Correlates PassHeaders with content (TextInput or TakeComplete) and
  dispatches assembled turns to the Epoch pipeline.

  For each pass, Transport emits a PassHeader (routing metadata) and a
  content message (TextInput for text, segment_received for audio).
  TurnAssembler holds both sides keyed by pass_id and fires when the
  pair is complete.

  Media uses take_id; Inference uses pass_id. For audio passes,
  PassHeader carries both and TurnAssembler maintains a take_id → pass_id
  index for correlation. TakeCollector (Media) handles both single-segment
  and multi-segment transcription assembly, emitting take_complete events
  that TurnAssembler correlates with PassHeaders.
  """

  use GenServer
  require Logger

  alias Cranium.Messages.{PassHeader, TextInput, TakeComplete}

  @stale_timeout_ms :timer.minutes(5)
  @sweep_interval_ms :timer.minutes(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Cranium.Events.subscribe()
    schedule_sweep()
    {:ok, %{pending: %{}, take_index: %{}}}
  end

  # --- PassHeader arrives: cache and check for matching content ---

  @impl true
  def handle_info({:pass_header, %PassHeader{pass_id: pass_id} = header}, state) do
    Logger.debug("TurnAssembler: header received pass=#{pass_id}")
    state = put_field(state, pass_id, :header, header)

    # If this pass has an associated take, index it for transcription lookup
    state =
      if header.take_id do
        %{state | take_index: Map.put(state.take_index, header.take_id, pass_id)}
      else
        state
      end

    {:noreply, maybe_dispatch(state, pass_id)}
  end

  # --- TextInput arrives: cache and check for matching header ---

  @impl true
  def handle_info({:text_input, %TextInput{pass_id: pass_id} = input}, state) do
    Logger.debug("TurnAssembler: text_input received pass=#{pass_id}")
    state = put_field(state, pass_id, :input, input)
    {:noreply, maybe_dispatch(state, pass_id)}
  end

  # --- TakeComplete (audio path — both single-segment and chunked) ---

  @impl true
  def handle_info(
        {:take_complete, %TakeComplete{take_id: take_id} = tc},
        state
      )
      when not is_nil(take_id) do
    case Map.get(state.take_index, take_id) do
      nil ->
        Logger.warning("TurnAssembler: take_complete for unknown take=#{take_id}")
        {:noreply, state}

      pass_id ->
        Logger.debug("TurnAssembler: take_complete received take=#{take_id} pass=#{pass_id}")
        state = put_field(state, pass_id, :input, tc)
        {:noreply, maybe_dispatch(state, pass_id)}
    end
  end

  # --- Sweep stale entries ---

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @stale_timeout_ms
    stale = for {id, %{inserted_at: t}} <- state.pending, t < cutoff, do: id

    if stale != [] do
      Logger.warning("TurnAssembler: sweeping #{length(stale)} stale passes")
    end

    # Clean up take_index entries for stale passes
    stale_set = MapSet.new(stale)

    take_index =
      state.take_index
      |> Enum.reject(fn {_take_id, pass_id} -> MapSet.member?(stale_set, pass_id) end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | pending: Map.drop(state.pending, stale), take_index: take_index}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp put_field(state, pass_id, field, value) do
    entry =
      Map.get(state.pending, pass_id, %{
        header: nil,
        input: nil,
        inserted_at: System.monotonic_time(:millisecond)
      })

    entry = Map.put(entry, field, value)
    %{state | pending: Map.put(state.pending, pass_id, entry)}
  end

  defp maybe_dispatch(state, pass_id) do
    case Map.get(state.pending, pass_id) do
      %{header: %PassHeader{} = header, input: input} when not is_nil(input) ->
        dispatch_to_epoch(header, input)

        # Clean up take_index if this pass had a take
        take_index =
          if header.take_id,
            do: Map.delete(state.take_index, header.take_id),
            else: state.take_index

        %{state | pending: Map.delete(state.pending, pass_id), take_index: take_index}

      _ ->
        state
    end
  end

  defp dispatch_to_epoch(%PassHeader{} = header, input) do
    text =
      case input do
        %TextInput{text: text} -> text
        %TakeComplete{text: text} -> "[Transcribed from audio]\n#{text}"
      end

    Logger.info(
      "TurnAssembler: dispatching pass=#{header.pass_id} conversation=#{header.conversation_id}",
      transport: :turn_assembler
    )

    Task.start(fn ->
      case Cranium.Epoch.start_or_get(header.conversation_id) do
        {:ok, epoch_pid} ->
          dispatch =
            Cranium.Dispatch.from_submit(%{
              conversation_id: header.conversation_id,
              model: header.model,
              disposition: header.disposition,
              ephemeral: header.ephemeral
            })

          message = %{
            text: text,
            system: header.system,
            conversation_id: header.conversation_id,
            stream_id: header.stream_id,
            disposition: header.disposition,
            origin: header.origin,
            model: header.model,
            ephemeral: header.ephemeral,
            dispatch: dispatch
          }

          case Cranium.Epoch.submit(epoch_pid, message) do
            {:ok, _} ->
              Cranium.TTS.Cache.schedule_cleanup(header.stream_id)

            {:error, :cancelled} ->
              Logger.info("TurnAssembler: submit cancelled pass=#{header.pass_id}",
                transport: :turn_assembler
              )

              Cranium.Manifest.cancel(header.stream_id)

            {:error, reason} ->
              Logger.error(
                "TurnAssembler: submit failed pass=#{header.pass_id} reason=#{inspect(reason)}",
                transport: :turn_assembler
              )

              Cranium.Manifest.complete(header.stream_id)
          end
      end
    end)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end

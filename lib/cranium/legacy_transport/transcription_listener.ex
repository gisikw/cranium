defmodule Cranium.LegacyTransport.TranscriptionListener do
  @moduledoc """
  Legacy bridge: feeds transcription results into SegmentRegistry for the
  HTTP done endpoint's missing-chunk response.

  Completion dispatch is now handled by TakeCollector → TurnAssembler.
  This module only exists to keep SegmentRegistry's chunk tracking in sync
  for the `/v1/input/:id/done` HTTP response.
  """

  use GenServer
  require Logger

  alias Cranium.Messages.Transcription

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Cranium.Events.subscribe()
    {:ok, %{}}
  end

  # Chunked path: feed transcribed text into SegmentRegistry for tracking.
  # Completion dispatch is handled by TakeCollector, not here.
  @impl true
  def handle_info(
        {:transcription_complete,
         %Transcription{text: text, take_id: take_id, seq: seq}},
        state
      )
      when not is_nil(seq) do
    case Cranium.Transport.SegmentRegistry.put_chunk(take_id, seq, text) do
      {:ok, :buffered} ->
        :ok

      {:ok, :complete, _result} ->
        # Completion dispatch handled by TakeCollector
        :ok

      {:error, reason} ->
        Logger.error(
          "TranscriptionListener: put_chunk failed take=#{take_id} seq=#{seq} reason=#{inspect(reason)}",
          transport: :http
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end

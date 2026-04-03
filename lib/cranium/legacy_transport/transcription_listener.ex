defmodule Cranium.LegacyTransport.TranscriptionListener do
  @moduledoc """
  Temporary bridge: handles the chunked audio path only.

  Listens for transcription_complete events from the Transcoder and routes
  transcribed chunks back into TakeRegistry for reassembly. When a take
  completes, dispatches to the Epoch pipeline.

  The submit path (text and single-audio) is now handled by
  Cranium.Inference.TurnAssembler via PassHeader/TextInput correlation.

  Will be removed once TakeCollector replaces TakeRegistry.
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

  # Chunked path: route transcribed text back into TakeRegistry.
  # Sequenced transcriptions (seq != nil) are chunked audio; single-segment
  # transcriptions (seq == nil) are handled by TurnAssembler.
  @impl true
  def handle_info(
        {:transcription_complete,
         %Transcription{text: text, take_id: take_id, seq: seq}},
        state
      )
      when not is_nil(seq) do
    Logger.info(
      "TranscriptionListener: chunk transcribed take=#{take_id} seq=#{seq}",
      transport: :http
    )

    case Cranium.Input.TakeRegistry.put_chunk(take_id, seq, text) do
      {:ok, :buffered} ->
        :ok

      {:ok, :complete, result} ->
        trigger_text_inference(result, take_id)

      {:error, reason} ->
        Logger.error(
          "TranscriptionListener: put_chunk failed take=#{take_id} seq=#{seq} reason=#{inspect(reason)}",
          transport: :http
        )
    end

    {:noreply, state}
  end

  # Chunked path failure
  @impl true
  def handle_info(
        {:transcription_failed,
         %Transcription{take_id: take_id, seq: seq}},
        state
      )
      when not is_nil(seq) do
    Logger.error(
      "TranscriptionListener: chunk STT failed take=#{take_id} seq=#{seq}",
      transport: :http
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Assembles the completed take result into a message and submits to Epoch.
  defp trigger_text_inference(result, take_id) do
    Task.start(fn ->
      content_key = result.disposition |> List.first("text") |> String.to_atom()
      raw_text = Map.fetch!(result, content_key)
      text = if content_key == :audio, do: "[Transcribed from audio]\n#{raw_text}", else: raw_text

      Logger.info(
        "TranscriptionListener: input complete take=#{take_id} text=#{inspect(String.slice(text, 0..80))}",
        transport: :http
      )

      case Cranium.Epoch.start_or_get(result.conversation_id) do
        {:ok, epoch_pid} ->
          message = %{
            text: text,
            conversation_id: result.conversation_id,
            stream_id: result.stream_id,
            disposition: result.disposition,
            origin: result.origin
          }

          case Cranium.Epoch.submit(epoch_pid, message) do
            {:ok, _} ->
              Cranium.TTS.Cache.schedule_cleanup(result.stream_id)

            {:error, :cancelled} ->
              Logger.info("Input submit cancelled: take=#{take_id}", transport: :http)
              Cranium.Manifest.cancel(result.stream_id)

            {:error, reason} ->
              Logger.error(
                "Input submit failed: take=#{take_id} reason=#{inspect(reason)}",
                transport: :http
              )

              Cranium.Manifest.complete(result.stream_id)
          end
      end
    end)
  end
end

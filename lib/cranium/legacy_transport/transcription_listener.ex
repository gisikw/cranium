defmodule Cranium.LegacyTransport.TranscriptionListener do
  @moduledoc """
  Temporary bridge: listens for transcription_complete events from the new
  Cranium.Media.Transcoder actor and dispatches to the legacy Epoch pipeline.

  This exists to let the new OTP actor handle STT while the rest of the
  pipeline remains unchanged. Will be removed once the full actor hierarchy
  replaces the Epoch/pipeline system.
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

  # Chunked path: route transcribed text back into TakeRegistry
  @impl true
  def handle_info(
        {:transcription_complete,
         %Transcription{text: text, legacy_metadata: %{take_id: take_id, seq: seq}}},
        state
      ) do
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

  # Submit path: dispatch to Epoch
  @impl true
  def handle_info(
        {:transcription_complete, %Transcription{text: text, legacy_metadata: meta}},
        state
      )
      when is_map(meta) do
    body = "[Transcribed from audio]\n#{text}"

    epoch_pid =
      case Cranium.Epoch.start_or_get(meta.conversation_id) do
        {:ok, pid} -> pid
      end

    message = %{
      text: body,
      system: meta[:system],
      conversation_id: meta.conversation_id,
      stream_id: meta.stream_id,
      disposition: meta[:disposition],
      origin: meta[:origin],
      model: meta[:model],
      ephemeral: meta[:ephemeral],
      dispatch: meta[:dispatch]
    }

    Logger.info(
      "TranscriptionListener: dispatching stream=#{meta.stream_id} conversation=#{meta.conversation_id}",
      transport: :http
    )

    Task.start(fn ->
      case Cranium.Epoch.submit(epoch_pid, message) do
        {:ok, _result} ->
          Cranium.TTS.Cache.schedule_cleanup(meta.stream_id)

        {:error, :cancelled} ->
          Logger.info("Submit cancelled: stream=#{meta.stream_id}", transport: :http)
          Cranium.Manifest.cancel(meta.stream_id)

        {:error, reason} ->
          Logger.error(
            "Submit failed: stream=#{meta.stream_id} reason=#{inspect(reason)}",
            transport: :http
          )

          Cranium.Manifest.complete(meta.stream_id)
      end
    end)

    {:noreply, state}
  end

  # Chunked path failure
  @impl true
  def handle_info(
        {:transcription_failed,
         %Transcription{legacy_metadata: %{take_id: take_id, seq: seq}}},
        state
      ) do
    Logger.error(
      "TranscriptionListener: chunk STT failed take=#{take_id} seq=#{seq}",
      transport: :http
    )

    {:noreply, state}
  end

  # Submit path failure
  @impl true
  def handle_info({:transcription_failed, %Transcription{legacy_metadata: meta}}, state)
      when is_map(meta) do
    Logger.error(
      "TranscriptionListener: STT failed for stream=#{meta.stream_id}",
      transport: :http
    )

    Cranium.Manifest.complete(meta.stream_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Mirrors Transport.HTTP.trigger_text_inference/2 — assembles the completed
  # take result into a message and submits to the Epoch pipeline.
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

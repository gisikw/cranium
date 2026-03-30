defmodule Cranium.Event do
  @moduledoc """
  Shared event vocabulary and broadcast for the firehose.

  Any module can emit events. Three broadcast scopes, each nesting into
  the next:

  - `broadcast(stream_id, conversation_id, event)` — per-stream + conversation + global
  - `broadcast(conversation_id, event)` — conversation + global
  - `broadcast(event)` — global only

  ## Event Types

  **Stream events** — emitted by Agent during inference:

  - `{:stream_start, stream_id, metadata}` — inference pass begins
  - `{:chunk, stream_id, content}` — text, marker, tool_use, or tool_result
  - `{:stream_end, stream_id}` — inference pass complete

  **Lifecycle events** — emitted by Epoch, Effects, etc.:

  - `{:epoch_started, conversation_id, epoch_id}` — new epoch created
  - `{:epoch_cleared, conversation_id, epoch_id}` — epoch cleared (handoff triggered)
  - `{:saturation_changed, conversation_id, value}` — context window saturation updated
  - `{:handoff_complete, conversation_id, epoch_id}` — handoff generation finished
  - `{:status_changed, conversation_id, status}` — epoch status transition

  **Rendition events** — emitted by Egress/TTS pipeline:

  - `{:segment_ready, stream_id, index, renditions}` — segment available for retrieval
  - `{:tts_complete, stream_id, index}` — audio synthesis finished for segment
  """

  # -- Stream events (Agent inference) --

  @type chunk_content ::
          binary()
          | {:marker, map()}
          | {:tool_use, map()}
          | {:tool_result, map()}

  @type stream_event ::
          {:stream_start, stream_id :: String.t(), metadata :: map()}
          | {:chunk, stream_id :: String.t(), chunk_content()}
          | {:stream_end, stream_id :: String.t()}

  # -- Lifecycle events (Epoch, Effects) --

  @type lifecycle_event ::
          {:epoch_started, conversation_id :: String.t(), epoch_id :: String.t()}
          | {:epoch_cleared, conversation_id :: String.t(), epoch_id :: String.t()}
          | {:saturation_changed, conversation_id :: String.t(), value :: float()}
          | {:handoff_complete, conversation_id :: String.t(), epoch_id :: String.t()}
          | {:status_changed, conversation_id :: String.t(),
             status :: :idle | :processing | :inferring | :cancelled}

  # -- Rendition events (Egress/TTS) --

  @type rendition_event ::
          {:segment_ready, stream_id :: String.t(), index :: non_neg_integer(),
           renditions :: [atom()]}
          | {:tts_complete, stream_id :: String.t(), index :: non_neg_integer()}

  @type t :: stream_event() | lifecycle_event() | rendition_event()

  @doc """
  Broadcast to global topic only.

  Use for system-wide events not scoped to a conversation.
  """
  @spec broadcast(t()) :: :ok
  def broadcast(event) do
    dispatch({:global}, event)
  end

  @doc """
  Broadcast to conversation and global topics.

  Use for conversation-scoped events (epoch lifecycle, saturation, etc.).
  """
  @spec broadcast(String.t(), t()) :: :ok
  def broadcast(conversation_id, event) do
    dispatch({:conversation, conversation_id}, event)
    broadcast(event)
  end

  @doc """
  Broadcast to per-stream, conversation, and global topics.

  Use for stream-scoped events (chunks, stream_start/end).
  """
  @spec broadcast(String.t(), String.t(), t()) :: :ok
  def broadcast(stream_id, conversation_id, event) do
    dispatch({:stream_raw, stream_id}, event)
    broadcast(conversation_id, event)
  end

  defp dispatch(key, event) do
    Registry.dispatch(Cranium.StreamRegistry, key, fn entries ->
      for {pid, _value} <- entries, do: send(pid, event)
    end)

    :ok
  end
end

defmodule Cranium.Calls.Delivery do
  @moduledoc """
  Pass submission for delivered calls.

  Private to `Cranium.Calls` — the plumbing that lands a call in the
  target room as a normal inference pass, exactly like an external
  submit (pass_header + text_input broadcast, TurnAssembler queueing
  applies). Swappable via `config :cranium, :call_delivery` so tests
  can intercept delivery without spawning real conversations.
  """

  alias Cranium.Messages.{PassHeader, TextInput}

  @callback deliver(map()) :: {:ok, String.t()} | {:error, String.t()}

  @behaviour __MODULE__

  @doc """
  Submit a call pass to `request.target_room`.

  Returns `{:ok, stream_id}` — the stream id of the receiving pass, used
  by `Cranium.Calls` to detect the receiver's turn boundary.
  """
  @impl true
  @spec deliver(map()) :: {:ok, String.t()} | {:error, String.t()}
  def deliver(request) do
    %{target_room: room, text: text} = request

    pass_id = Cranium.Stage.new_stream_id()
    stream_id = Cranium.Stage.new_stream_id()

    Cranium.Transport.Manifest.init_stream(stream_id, room, disposition: ["text"])
    Cranium.Inference.Conversation.start_or_get(room)

    header = %PassHeader{
      pass_id: pass_id,
      conversation_id: room,
      stream_id: stream_id,
      origin: request[:origin],
      profile: request[:profile],
      disposition: ["text"],
      depth: request[:depth]
    }

    Cranium.Events.broadcast({:pass_header, header})
    Cranium.Events.broadcast({:text_input, %TextInput{pass_id: pass_id, text: text}})

    {:ok, stream_id}
  rescue
    e -> {:error, Exception.message(e)}
  end
end

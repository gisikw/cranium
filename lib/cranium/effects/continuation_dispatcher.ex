defmodule Cranium.Effects.ContinuationDispatcher do
  @moduledoc """
  Dispatches continuation passes after handoff completion.

  When an agent calls `clear_context` with a continuation argument, the
  continuation is stored on the new epoch. This GenServer listens for
  `{:handoff_complete, ...}` events and, if the conversation's epoch has
  a pending continuation, starts a new pass with that text.

  The continuation is cleared after dispatch to prevent re-firing.
  """

  use GenServer

  require Logger

  alias Cranium.Messages.{PassHeader, TextInput}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Cranium.Events.subscribe(:global)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:handoff_complete, conversation_id, _meta}, state) do
    case Cranium.Store.get_epoch(conversation_id) do
      {:ok, %{continuation: continuation}} when is_binary(continuation) and continuation != "" ->
        Logger.info("Dispatching continuation pass",
          conversation_id: conversation_id,
          continuation_preview: String.slice(continuation, 0..80)
        )

        dispatch_continuation(conversation_id, continuation)

      _ ->
        # No continuation or epoch not found — nothing to do
        :ok
    end

    {:noreply, state}
  end

  # Ignore all other events
  def handle_info(_event, state) do
    {:noreply, state}
  end

  defp dispatch_continuation(conversation_id, continuation) do
    pass_id = Cranium.Stage.new_stream_id()
    stream_id = Cranium.Stage.new_stream_id()

    # Clear continuation to prevent re-firing on future handoffs
    case Cranium.Store.get_epoch(conversation_id) do
      {:ok, %{id: epoch_id, profile: profile}} ->
        Cranium.Store.update_epoch(epoch_id, %{continuation: nil})

        # Initialize manifest for this stream
        Cranium.Transport.Manifest.init_stream(stream_id, conversation_id, disposition: ["text"])

        # Ensure per-conversation TurnAssembler exists
        Cranium.Inference.Conversation.start_or_get(conversation_id)

        header = %PassHeader{
          pass_id: pass_id,
          conversation_id: conversation_id,
          stream_id: stream_id,
          origin: "continuation",
          profile: profile,
          disposition: ["text"]
        }

        input = %TextInput{
          pass_id: pass_id,
          text: continuation
        }

        Cranium.Events.broadcast({:pass_header, header})
        Cranium.Events.broadcast({:text_input, input})

      :not_found ->
        Logger.warning("Epoch not found for continuation dispatch",
          conversation_id: conversation_id
        )
    end
  end
end

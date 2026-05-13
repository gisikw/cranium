defmodule Cranium do
  @moduledoc """
  Cranium — a streaming message pipeline bridging conversational interfaces
  to LLM inference.

  Public API for epoch lifecycle and inference control.
  """

  @doc """
  Clear the epoch for a conversation.

  Cancels any active inference, marks the current epoch as cleared,
  generates a handoff document (async), and creates a fresh epoch.
  The next message will start with the handoff injected.

  ## Options

    * `:source` - origin identifier for the clear event (e.g., "submit", "api", "tool")
    * `:continuation` - instruction to execute after handoff completes. If provided,
      the ContinuationDispatcher will start a new pass with this text once the
      handoff finishes generating.
  """
  @spec clear_epoch(String.t(), keyword()) :: :ok
  def clear_epoch(conversation_id, opts \\ []) do
    source = Keyword.get(opts, :source)
    continuation = Keyword.get(opts, :continuation)

    case Cranium.Store.get_epoch(conversation_id) do
      {:ok, epoch} ->
        cancel(conversation_id)

        # Dispatch on_epoch_end hooks before clearing — plugins still have
        # their state and messages are still accessible.
        {:ok, messages} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch.id)

        epoch_end_context = %{
          conversation_id: conversation_id,
          epoch_id: epoch.id,
          messages: messages
        }

        Cranium.Plugin.ConversationSupervisor.dispatch_epoch_end(
          conversation_id,
          epoch_end_context
        )

        Cranium.Store.clear_epoch(conversation_id, continuation)

        Cranium.Events.broadcast(
          conversation_id,
          {:epoch_cleared, conversation_id, %{epoch_id: epoch.id, source: source}}
        )

        Cranium.Effects.generate_handoff(conversation_id, epoch.id, epoch.cc_session_id, epoch.profile)
        :ok

      :not_found ->
        :ok
    end
  end

  @doc """
  Cancel active inference for a conversation.

  Kills the inference process immediately. In-flight output drains naturally.
  Partial context is captured for the interrupted context breadcrumb.
  """
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(conversation_id) do
    case Cranium.Inference.Harness.cancel(conversation_id) do
      :ok -> :ok
      :not_found -> {:error, :no_active_inference}
    end
  end
end

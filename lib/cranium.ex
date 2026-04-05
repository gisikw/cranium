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
  """
  @spec clear_epoch(String.t(), keyword()) :: :ok
  def clear_epoch(conversation_id, opts \\ []) do
    source = Keyword.get(opts, :source)

    case Cranium.Store.get_epoch(conversation_id) do
      {:ok, epoch} ->
        cancel(conversation_id)
        Cranium.Store.clear_epoch(conversation_id)

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

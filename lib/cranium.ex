defmodule Cranium do
  @moduledoc """
  Cranium — a streaming message pipeline bridging conversational interfaces
  to LLM inference.

  This module provides the public API for submitting messages, managing epochs,
  and controlling the pipeline.
  """

  @doc """
  Process a message for a given conversation.

  Starts an epoch if one isn't active, routes the message through the pipeline
  (Ingress → Context → Agent → Egress), and delivers the response via the
  originating transport.

  Returns `{:ok, epoch_id}` on success, `{:error, reason}` on failure.
  """
  @spec process_message(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def process_message(conversation_id, message) do
    case Cranium.Epoch.start_or_get(conversation_id) do
      {:ok, epoch} -> Cranium.Epoch.submit(epoch, message)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clear the epoch for a conversation.

  Triggers handoff generation (async), then resets the epoch state.
  The next message will start a fresh epoch with the handoff injected.
  """
  @spec clear_epoch(String.t()) :: :ok | {:error, term()}
  def clear_epoch(conversation_id) do
    case Cranium.Epoch.lookup(conversation_id) do
      {:ok, epoch} -> Cranium.Epoch.clear(epoch)
      :not_found -> :ok
    end
  end

  @doc """
  Cancel active inference for a conversation.

  Kills the inference process immediately. In-flight output drains naturally.
  Partial context is captured for the interrupted context breadcrumb.
  """
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(conversation_id) do
    case Cranium.Epoch.cancel(conversation_id) do
      :ok -> :ok
      :not_found -> {:error, :no_active_epoch}
    end
  end
end

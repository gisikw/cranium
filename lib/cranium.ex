defmodule Cranium do
  @moduledoc """
  Cranium — a streaming message pipeline bridging conversational interfaces
  to LLM inference.

  This module provides the public API for submitting messages, managing sessions,
  and controlling the pipeline.
  """

  @doc """
  Process a message for a given room.

  Starts a session if one isn't active, routes the message through the pipeline
  (Ingress → Context → Agent → Egress), and delivers the response via the
  originating transport.

  Returns `{:ok, session_id}` on success, `{:error, reason}` on failure.
  """
  @spec process_message(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def process_message(room_id, message) do
    case Cranium.Session.start_or_get(room_id) do
      {:ok, session} -> Cranium.Session.submit(session, message)
      {:error, :already_active} -> {:error, :already_active}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clear the session for a room.

  Triggers handoff generation (async), then resets the session state.
  The next message will start a fresh session with the handoff injected.
  """
  @spec clear_session(String.t()) :: :ok | {:error, term()}
  def clear_session(room_id) do
    case Cranium.Session.lookup(room_id) do
      {:ok, session} -> Cranium.Session.clear(session)
      :not_found -> :ok
    end
  end

  @doc """
  Cancel active inference for a room.

  Kills the inference process immediately. In-flight output drains naturally.
  Partial context is captured for the interrupted context breadcrumb.
  """
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(room_id) do
    case Cranium.Session.lookup(room_id) do
      {:ok, session} -> Cranium.Session.cancel(session)
      :not_found -> {:error, :no_active_session}
    end
  end
end

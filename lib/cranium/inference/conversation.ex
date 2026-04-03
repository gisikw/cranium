defmodule Cranium.Inference.Conversation do
  @moduledoc """
  Per-conversation supervisor that owns a TurnAssembler + Harness pair.

  Uses `:one_for_all` strategy — if either crashes, both restart. These
  processes are a unit: the assembler feeds the harness, and a crash in
  one invalidates the other's state.

  ## Lifecycle

  Started on demand via `start_or_get/1` when the first message arrives
  for a conversation. Registered in ConversationRegistry by conversation_id.
  """

  use Supervisor

  @registry Cranium.Inference.ConversationRegistry
  @dynamic_sup Cranium.Inference.ConversationDynamicSupervisor

  @doc """
  Start a per-conversation supervisor, or return the existing one.
  """
  @spec start_or_get(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_or_get(conversation_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               @dynamic_sup,
               {__MODULE__, conversation_id: conversation_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Look up the per-conversation supervisor.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :not_found
  def lookup(conversation_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    Supervisor.start_link(__MODULE__, opts, name: via(conversation_id))
  end

  defp via(conversation_id) do
    {:via, Registry, {@registry, conversation_id}}
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    children = [
      {Cranium.Inference.TurnAssembler, conversation_id: conversation_id},
      {Cranium.Inference.Harness, conversation_id: conversation_id}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

defmodule Cranium.Inference.Harness do
  @moduledoc """
  Per-conversation inference executor.

  Subscribes to assembled turn events, manages the CC agent process
  lifecycle, and emits pass_complete/pass_cancelled events. Pure inference
  execution — no Store access, no bookkeeping.

  Currently a skeleton. Phase 3 will wire it to receive assembled turns
  from TurnAssembler and replace Epoch's inference execution role.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    GenServer.start_link(__MODULE__, opts, name: via(conversation_id))
  end

  defp via(conversation_id) do
    {:via, Registry, {Cranium.Inference.ConversationRegistry, {conversation_id, :harness}}}
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    Logger.metadata(conversation_id: conversation_id)
    {:ok, %{conversation_id: conversation_id}}
  end
end

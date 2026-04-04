defmodule Cranium.Events do
  @moduledoc """
  Unified event broadcast and subscription.

  Three broadcast scopes, each nesting into the next:

  - `broadcast(stream_id, conversation_id, event)` — per-stream + conversation + global
  - `broadcast(conversation_id, event)` — conversation + global
  - `broadcast(event)` — global only

  Subscription topics:

  - `:global` — all events
  - `{:conversation, id}` — events for a specific conversation
  - `{:stream_raw, id}` — events for a specific stream
  """

  @registry Cranium.Events.Registry

  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  def subscribe, do: subscribe(:global)
  def subscribe(topic), do: Registry.register(@registry, topic, [])

  @doc "Broadcast to global topic only."
  def broadcast(event) do
    dispatch(:global, event)
  end

  @doc "Broadcast to conversation and global topics."
  def broadcast(conversation_id, event) do
    dispatch(:global, event)
    dispatch({:conversation, conversation_id}, event)
  end

  @doc "Broadcast to stream, conversation, and global topics."
  def broadcast(stream_id, conversation_id, event) do
    dispatch(:global, event)
    dispatch({:conversation, conversation_id}, event)
    dispatch({:stream_raw, stream_id}, event)
  end

  defp dispatch(key, event) do
    Registry.dispatch(@registry, key, fn entries ->
      for {pid, _value} <- entries, do: send(pid, event)
    end)

    :ok
  end
end

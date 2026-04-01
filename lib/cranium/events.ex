defmodule Cranium.Events do
  @registry Cranium.Events.Registry

  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  def subscribe, do: subscribe(:global)
  def subscribe(topic), do: Registry.register(@registry, topic, [])

  def broadcast(message), do: broadcast(:global, message)
  def broadcast(topic, message) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _value} <- entries, do: send(pid, message)
    end)
  end
end

defmodule Cranium.Media do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Cranium.Media.Storage,
      Cranium.Media.Transcoder,
      Cranium.Media.TakeCollector
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

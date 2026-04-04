defmodule Cranium.Transport do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Cranium.Transport.SegmentRegistry,
      Cranium.Transport.Manifest,
      {Bandit, plug: Cranium.Transport.HTTP, port: http_port()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp http_port do
    Application.get_env(:cranium, :http_port, 4000)
  end
end

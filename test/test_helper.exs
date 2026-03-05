ExUnit.start()

# Only configure Ecto sandbox when the Repo is started
if Process.whereis(Cranium.Store.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Cranium.Store.Repo, :manual)
end

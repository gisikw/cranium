Application.ensure_all_started(:mox)
Application.ensure_all_started(:req)

# Start services needed by tests when running with --no-start
Cranium.Manifest.start_link(name: Cranium.Manifest)
Cranium.TTS.Cache.start_link(name: Cranium.TTS.Cache)

ExUnit.start()

# Only configure Ecto sandbox when the Repo is started
if Process.whereis(Cranium.Store.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Cranium.Store.Repo, :manual)
end

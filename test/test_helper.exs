Application.ensure_all_started(:mox)
Application.ensure_all_started(:req)

# Start services needed by tests when running with --no-start
unless Process.whereis(Cranium.Store.Repo) do
  # Repo needs postgrex and ecto_sql applications
  Application.ensure_all_started(:postgrex)
  Application.ensure_all_started(:ecto_sql)
  Cranium.Store.Repo.start_link([])
end

Cranium.Manifest.start_link(name: Cranium.Manifest)
Cranium.TTS.Cache.start_link(name: Cranium.TTS.Cache)
Cranium.Input.TakeRegistry.start_link(name: Cranium.Input.TakeRegistry)
Cranium.Media.OutputSegmenter.start_link([])

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(Cranium.Store.Repo, :manual)

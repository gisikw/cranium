Application.ensure_all_started(:mox)
Application.ensure_all_started(:req)

# Start services needed by tests when running with --no-start
unless Process.whereis(Cranium.Store.Repo) do
  # Repo needs postgrex and ecto_sql applications
  Application.ensure_all_started(:postgrex)
  Application.ensure_all_started(:ecto_sql)
  Cranium.Store.Repo.start_link([])
end

# Ensure event registry is running (no-op if already started by application supervisor)
unless Process.whereis(Cranium.Events.Registry) do
  Registry.start_link(keys: :duplicate, name: Cranium.Events.Registry)
end

Cranium.Transport.Manifest.start_link(name: Cranium.Transport.Manifest)
Cranium.Media.TTS.Cache.start_link(name: Cranium.Media.TTS.Cache)
Cranium.Transport.SegmentRegistry.start_link(name: Cranium.Transport.SegmentRegistry)
Cranium.Media.OutputSegmenter.start_link([])
Cranium.Calls.start_link([])

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(Cranium.Store.Repo, :manual)

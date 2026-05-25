import Config

config :cranium, Cranium.Store.Repo,
  username: "postgres",
  password: "",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Use test backends
config :cranium, :backends,
  tts: Cranium.Backend.TTS.Mock,
  llm: Cranium.Backend.LLM.Mock,
  tts_url: "http://localhost:9999/v1/audio/speech",
  stt_url: "http://localhost:9999/transcribe"

# Audio compat endpoint backends (mockable)
config :cranium, :tts_backend, Cranium.Backend.TTS.Mock
config :cranium, :stt_backend, Cranium.Backend.STT.Mock

# Port 0 = OS-assigned random port. Tests use Plug.Test.conn directly,
# so Bandit's actual port doesn't matter. Avoids eaddrinuse races.
config :cranium, :http_port, 0

# Test paths — provide safe defaults so HandoffWriter, PromptBuilder, etc.
# don't crash on nil. Runtime.exs env vars aren't set in test.
config :cranium, :paths,
  handoffs: System.tmp_dir!(),
  summaries: System.tmp_dir!(),
  skills: Path.join(File.cwd!(), "skills"),
  subagent_prompt: nil

# Profile config — test fixture
config :cranium, :profiles_path, Path.join(File.cwd!(), "test/fixtures/profiles.yaml")

# TTS prosody config — test fixture
config :cranium, :tts_config_path, Path.join(File.cwd!(), "test/fixtures/tts.yaml")

config :logger, level: :warning

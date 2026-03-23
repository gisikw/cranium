import Config

config :cranium, Cranium.Store.Repo,
  username: "postgres",
  password: "",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Use test backends
config :cranium, :backends,
  stt: Cranium.Backend.STT.Mock,
  tts: Cranium.Backend.TTS.Mock,
  llm: Cranium.Backend.LLM.Mock,
  tts_url: "http://localhost:9999/v1/audio/speech",
  stt_url: "http://localhost:9999/transcribe"

# Port 0 = OS-assigned random port. Tests use Plug.Test.conn directly,
# so Bandit's actual port doesn't matter. Avoids eaddrinuse races.
config :cranium, :http_port, 0

# Test paths — provide safe defaults so HandoffWriter, PromptBuilder, etc.
# don't crash on nil. Runtime.exs env vars aren't set in test.
config :cranium, :paths,
  handoffs: System.tmp_dir!(),
  summaries: System.tmp_dir!(),
  skills: Path.join(File.cwd!(), "skills"),
  identity: nil,
  subagent_prompt: nil

config :logger, level: :warning

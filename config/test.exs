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
  llm: Cranium.Backend.LLM.Mock

config :cranium, :http_port, 4099

config :logger, level: :warning

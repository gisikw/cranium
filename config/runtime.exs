import Config

if config_env() == :prod do
  config :cranium, Cranium.Store.Repo,
    url: System.get_env("DATABASE_URL") || raise("DATABASE_URL not set"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  config :cranium, :backends,
    stt_url: System.get_env("STT_URL") || raise("STT_URL not set"),
    tts_url: System.get_env("TTS_URL") || raise("TTS_URL not set"),
    anthropic_api_key: System.get_env("ANTHROPIC_API_KEY") || raise("ANTHROPIC_API_KEY not set"),
    anthropic_model: System.get_env("ANTHROPIC_MODEL") || "claude-sonnet-4-6"
end

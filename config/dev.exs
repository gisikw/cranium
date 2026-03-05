import Config

config :cranium, Cranium.Store.Repo,
  username: "postgres",
  password: "",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Read API key from environment if available
if api_key = System.get_env("ANTHROPIC_API_KEY") do
  config :cranium, :backends,
    anthropic_api_key: api_key,
    anthropic_model: System.get_env("ANTHROPIC_MODEL") || "claude-haiku-4-5-20251001"
end

config :logger, level: :debug

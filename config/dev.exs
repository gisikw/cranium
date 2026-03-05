import Config

config :cranium, Cranium.Store.Repo,
  username: "postgres",
  password: "",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :logger, level: :debug

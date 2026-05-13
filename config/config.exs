import Config

config :cranium, ecto_repos: [Cranium.Store.Repo]

config :cranium, Cranium.Store.Repo,
  database: "cranium_#{config_env()}",
  hostname: "localhost"

# Backend configuration — swap implementations here
# To use Claude Code CLI instead of direct API, change llm to:
#   llm: Cranium.Backend.LLM.ClaudeCode
config :cranium, :backends,
  stt: Cranium.Backend.STT.Whisper,
  tts: Cranium.Backend.TTS.ExoVoice,
  llm: Cranium.Backend.LLM.ClaudeCode,
  claude_code_path: "claude"

# Tool registry — tools are registered at runtime via ToolRouter.register/2
config :cranium, :tools, []

# Paths — configured via environment variables. See .env.example.
config :cranium, :paths, []

# Rooms excluded from GET /v1/rooms (ops, infrastructure, etc.)
config :cranium, :excluded_rooms, []

# Pipeline tuning
config :cranium, :pipeline,
  summary_interval: 10,
  saturation_warn_threshold: 50,
  saturation_bucket_size: 5,
  max_context_tokens: 200_000,
  time_gap_threshold_seconds: 1800

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:conversation_id, :epoch_id, :stage]

import_config "#{config_env()}.exs"

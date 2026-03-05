import Config

config :cranium, ecto_repos: [Cranium.Store.Repo]

config :cranium, Cranium.Store.Repo,
  database: "cranium_#{config_env()}",
  hostname: "localhost"

# Backend configuration — swap implementations here
config :cranium, :backends,
  stt: Cranium.Backend.STT.Whisper,
  tts: Cranium.Backend.TTS.Kokoro,
  llm: Cranium.Backend.LLM.Anthropic

# Pipeline tuning
config :cranium, :pipeline,
  summary_interval: 10,
  saturation_warn_threshold: 50,
  saturation_bucket_size: 5,
  time_gap_threshold_seconds: 1800

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:conversation_id, :epoch_id, :stage]

import_config "#{config_env()}.exs"

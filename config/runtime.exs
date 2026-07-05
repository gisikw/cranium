import Config

# Paths — override from env vars when set. In test env, defaults
# come from test.exs; in dev, from .env; in prod, from systemd env.
# In test env, test.exs provides safe defaults — don't let env vars override
unless config_env() == :test do
  paths =
    [
      handoffs: System.get_env("HANDOFFS_PATH"),
      summaries: System.get_env("SUMMARIES_PATH"),
      skills: System.get_env("SKILLS_PATH"),
      subagent_prompt: System.get_env("SUBAGENT_PROMPT_PATH"),
      macros: System.get_env("MACROS_PATH"),
      macros_state: System.get_env("MACROS_STATE_PATH")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)

  if paths != [] do
    config :cranium, :paths, paths
  end

  if port = System.get_env("PORT") do
    config :cranium, :http_port, String.to_integer(port)
  end

  # Gee belief bridge — the artifact published by the gee-bridge-publisher
  # timer (single eval writer). Colocated on the same host/user, so the
  # transport is a plain file read.
  config :cranium, :gee_beliefs,
    bridge_path:
      System.get_env("GEE_BRIDGE_PATH") || Path.expand("~/.local/state/gee/bridge.txt"),
    manifest_path:
      System.get_env("GEE_BELIEF_MANIFEST_PATH") ||
        Path.expand("~/.local/state/cranium/belief-manifest.jsonl"),
    budget_fraction: 0.05
end

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

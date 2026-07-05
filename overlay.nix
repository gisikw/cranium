# Cranium overlay — evaluated by fort-overlay-manager at activation time.
# Arguments: storePath (injected by manager), config (from manifest.nix).
{ storePath, config ? {}, ... }:
{
  services.cranium = {
    exec = "/bin/sh -c '\"${storePath}/bin/cranium\" eval \"Cranium.Release.migrate()\" && exec \"${storePath}/bin/cranium\" start'";
    user = "dev";
    group = "users";
    workingDirectory = "/home/dev/Projects/cranium";
    after = [ "network-online.target" "postgresql.service" ];
    restart = "on-failure";
    restartSec = 5;
    timeoutStopSec = 300;
    environmentFile = [
      config.envFile or "/dev/null"
      "/var/lib/fort/dev-sandbox/env"
    ];
    environment = [
      "HOME=/home/dev"
      "PORT=${config.port or "4000"}"
      "RELEASE_COOKIE=cranium_cookie"
      "RELEASE_TMP=/tmp/cranium"
      "FORT_SSH_KEY=/var/lib/fort/dev-sandbox/agent-key"
      "FORT_ORIGIN=dev-sandbox"
      "MACROS_PATH=/home/dev/Projects/hoard/macros"
      "MACROS_STATE_PATH=/home/dev/.local/state/cranium/macros_state.json"
      # Gee belief bridge (docs/gee-belief-injection.md). Published by the
      # gee-bridge-publisher timer; cranium is read-only on both paths' domain.
      "GEE_BRIDGE_PATH=/home/dev/.local/state/gee/bridge.txt"
      "GEE_BELIEF_MANIFEST_PATH=/home/dev/.local/state/cranium/belief-manifest.jsonl"
    ] ++ (if config ? grottoUrl then [ "GROTTO_URL=${config.grottoUrl}" ] else [ ]) ++ [
      "PATH=/run/current-system/sw/bin:/run/overlays/bin:/run/managed-bin:/home/dev/.local/bin"
    ];
  };

  bins = [
    "${storePath}/bin/cranium"
  ];

  health = {
    type = "http";
    endpoint = "http://127.0.0.1:${config.port or "4000"}/health";
    grace = 3;
    interval = 1;
    stabilize = 2;
  };
}

# Cranium overlay — evaluated by fort-overlay-manager at activation time.
# Arguments: storePath (injected by manager), config (from manifest.nix).
{ storePath, config ? {}, ... }:
{
  services.cranium = {
    exec = "/bin/sh -c '\"${storePath}/bin/cranium\" eval \"Cranium.Release.migrate()\" && exec \"${storePath}/bin/cranium\" start'";
    user = "dev";
    group = "users";
    workingDirectory = "/home/dev/Projects/cranium-v2";
    after = [ "network-online.target" "postgresql.service" ];
    restart = "on-failure";
    restartSec = 5;
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
      "PATH=/run/current-system/sw/bin:/run/overlays/bin:/run/managed-bin:/home/dev/.local/bin"
    ];
  };

  bins = [
    "${storePath}/bin/cranium"
  ];

  health = {
    type = "none";
  };
}

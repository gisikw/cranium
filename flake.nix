{
  description = "Cranium v2 — Streaming message pipeline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        erlang = pkgs.erlang;
        elixir = pkgs.elixir;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            erlang
            elixir
            postgresql
            just
          ];

          shellHook = ''
            echo "cranium-v2 dev shell"
            echo "  mix test     — run tests"
            echo "  mix compile  — compile"
            echo "  iex -S mix   — interactive shell"
            echo "  just         — list recipes"
            echo ""
            echo "Elixir $(elixir --version | tail -1)"
            echo "Erlang/OTP $(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell)"
          '';

          ERL_INCLUDE_PATH = "${erlang}/lib/erlang/usr/include";

          # Locales for Elixir string handling
          LANG = "en_US.UTF-8";
          LC_ALL = "en_US.UTF-8";
        };
      }
    );
}

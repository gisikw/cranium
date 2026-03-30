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
        beamPackages = pkgs.beamPackages;
        erlang = pkgs.erlang;
        elixir = pkgs.elixir_1_19;

        mixNixDeps = import ./deps.nix {
          lib = pkgs.lib;
          inherit beamPackages;
        };
      in
      {
        # LOAD-BEARING: forces eager eval of beamPackages/mixNixDeps.
        # Without this, eachDefaultSystem drops the packages output
        # entirely when mixRelease eval is deferred. Don't remove
        # until we understand why.
        packages.debug = pkgs.writeText "cranium-debug" (builtins.toJSON {
          hasBeamPackages = builtins.hasAttr "beamPackages" pkgs;
          hasMixRelease = builtins.hasAttr "mixRelease" beamPackages;
          depCount = builtins.length (builtins.attrNames mixNixDeps);
        });

        packages.default = beamPackages.mixRelease {
          pname = "cranium";
          version = "0.1.0";
          src = ./.;
          inherit mixNixDeps elixir;

          # Override configurePhase to use ln -sfn instead of ln -sv.
          # The upstream builder's ln -sv fails when deps.compile has
          # already created a dep directory (e.g. mint via finch).
          configurePhase = ''
            runHook preConfigure

            mix deps.compile --no-deps-check --skip-umbrella-children

            mkdir -p deps
            ${pkgs.lib.concatMapAttrsStringSep "\n" (name: dep: ''
              if [ -d "${dep}/src" ]; then
                rm -rf deps/${name}/src 2>/dev/null || true
                ln -sv ${dep}/src deps/${name}
              fi
            '') mixNixDeps}

            runHook postConfigure
          '';

          postInstall = ''
            cp ${./overlay.nix} $out/overlay.nix
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            erlang
            elixir
            postgresql
            just
          ];

          shellHook = ''
            echo "cranium-v2 dev shell"
            echo "  just         — list recipes"
            echo ""
            echo "Elixir $(elixir --version | tail -1)"
            echo "Erlang/OTP $(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell)"
          '';

          ERL_INCLUDE_PATH = "${erlang}/lib/erlang/usr/include";

          LANG = "en_US.UTF-8";
          LC_ALL = "en_US.UTF-8";
        };
      }
    );
}

{
  description = "callosum — Matrix-to-agent dispatcher";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.buildGoModule {
          pname = "callosum";
          version = "0.1.0";
          src = ./.;
          tags = [ "goolm" ];
          vendorHash = null; # Update after first build
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ go gopls just ];

          shellHook = ''
            echo "callosum dev shell"
            echo "  just test    — run tests"
            echo "  just build   — build binary"
            echo "  just deploy  — build + upgrade"
          '';
        };
      }
    );
}

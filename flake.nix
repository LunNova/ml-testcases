# SPDX-FileCopyrightText: 2026 LunNova
#
# SPDX-License-Identifier: CC0-1.0

{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      pre-commit-hooks,
      rust-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        rust-bin = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
      in
      {
        checks = {
          pre-commit-check = pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              statix.enable = true;
              nixfmt.enable = true;
              deadnix.enable = true;
              ruff-format.enable = true;
              rustfmt = {
                enable = true;
                entry = "rustfmt --config-path ${./rustfmt.toml}";
                package = rust-bin;
              };
            };
          };
        };
        formatter = pkgs.treefmt.withConfig {
          runtimeInputs = with pkgs; [
            nixfmt
            ruff
            rust-bin
          ];
          settings = {
            tree-root-file = ".git/index";
            formatter = {
              nixfmt = {
                command = "nixfmt";
                includes = [ "*.nix" ];
              };
              ruff = {
                command = "ruff";
                options = [
                  "format"
                ];
                includes = [ "*.py" ];
              };
              rustfmt = {
                command = "rustfmt";
                options = pkgs.lib.mkForce [
                  "--config-path"
                  ./rustfmt.toml
                ];
                includes = [ "*.rs" ];
              };
            };
          };
        };

        packages.torch-triton-tests =
          let
            testDir = ./tests/torch-triton;
            python = pkgs.pkgsRocm.python3.withPackages (
              ps: with ps; [
                torch
                triton
                numpy
              ]
            );
          in
          pkgs.writeShellApplication {
            name = "torch-triton-tests";
            runtimeInputs = [
              python
              pkgs.gcc
            ];
            text = ''
              passes=0
              fails=0
              skips=0
              failed_tests=()

              for test in "${testDir}"/*.py; do
                name="$(basename "$test" .py)"
                echo "=== $name ==="
                set +e
                python3 "$test"
                rc=$?
                set -e
                case $rc in
                  0) passes=$((passes + 1)) ;;
                  2) skips=$((skips + 1)) ;;
                  *)
                    fails=$((fails + 1))
                    failed_tests+=("$name")
                    ;;
                esac
                echo ""
              done

              echo "=== torch-triton-tests summary ==="
              echo "PASS: $passes  FAIL: $fails  N/A: $skips"
              if [[ ''${#failed_tests[@]} -gt 0 ]]; then
                echo ""
                echo "Failed:"
                for t in "''${failed_tests[@]}"; do
                  echo "  - $t"
                done
                exit 1
              fi
            '';
          };

        devShells.default = pkgs.mkShell {
          inherit (self.checks.${system}.pre-commit-check) shellHook;

          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
          inherit (pkgs.cargo-llvm-cov) LLVM_COV LLVM_PROFDATA;
          buildInputs =
            (with pkgs; [
              pkg-config
              clang
              cargo-deny
              cargo-llvm-cov
              cargo-modules
              cargo-flamegraph
              cargo-nextest
              cargo-expand
              cargo-release
              cargo-workspaces
              cargo-machete
              libevdev
              reuse
              openssl.dev
              openssl
            ])
            ++ [ rust-bin ];

          # Set strict miri flags for memory safety validation
          MIRIFLAGS = "-Zmiri-strict-provenance -Zmiri-symbolic-alignment-check -Zmiri-tree-borrows";
        };
      }
    );
}

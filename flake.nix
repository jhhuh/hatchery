{
  description = "Hatchery – Haskell + C (musl-static) Linux process sandbox toolkit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      musl-cc = pkgs.pkgsStatic.stdenv.cc;

      hsPkgs = pkgs.haskellPackages.override {
        overrides = pkgs.lib.composeManyExtensions [
          # Local packages
          (pkgs.haskell.lib.packageSourceOverrides {
            hatchery      = ./hatchery;
            hatchery-llvm = ./hatchery-llvm;
            trustless-ffi = ./trustless-ffi;
          })
          # Pinned Hackage versions
          (hself: hsuper: {
            llvm-ffi = hself.callHackage "llvm-ffi" "21.0.0.2" {
              LLVM = pkgs.llvmPackages_19.llvm;
            };
            llvm-tf  = hself.callHackage "llvm-tf"  "21.0" {};
          })
        ];
      };

      haskellShell = hsPkgs.shellFor {
        packages = p: [ p.hatchery p.hatchery-llvm p.trustless-ffi ];
        buildInputs = [
          pkgs.cabal-install
          musl-cc
          pkgs.llvmPackages_19.llvm
          pkgs.nasm
          pkgs.overmind
          pkgs.tmux
        ];
        shellHook = ''
          export MUSL_CC="${musl-cc}/bin/x86_64-unknown-linux-musl-gcc"
        '';
      };
    in {
      devShells.${system}.default = haskellShell;
    };
}

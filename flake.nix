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
      llvm = pkgs.llvmPackages_19.llvm;

      hsPkgs = pkgs.haskellPackages.override {
        overrides = pkgs.lib.composeManyExtensions [
          (pkgs.haskell.lib.packageSourceOverrides {
            hatchery      = ./hatchery;
            hatchery-llvm = ./hatchery-llvm;
            trustless-ffi = ./trustless-ffi;
          })
          (hself: hsuper: {
            # Follow nixpkgs pattern from configuration-nix.nix:
            # pass LLVM = null, add .lib and .dev as build deps separately
            llvm-ffi = pkgs.haskell.lib.compose.addBuildDepends
              [ llvm.lib llvm.dev ]
              (hself.callHackage "llvm-ffi" "21.0.0.2" { LLVM = null; });
            llvm-tf = hself.callHackage "llvm-tf" "21.0" {};
          })
        ];
      };

      haskellShell = hsPkgs.shellFor {
        packages = p: [ p.hatchery p.hatchery-llvm p.trustless-ffi ];
        buildInputs = [
          pkgs.cabal-install
          musl-cc
          llvm
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

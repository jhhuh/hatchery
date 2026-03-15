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
      hatchery-cc = "${musl-cc}/bin/x86_64-unknown-linux-musl-gcc";
      llvm = pkgs.llvmPackages_19.llvm;

      hsPkgs = pkgs.haskellPackages.override {
        overrides = pkgs.lib.composeManyExtensions [
          (pkgs.haskell.lib.packageSourceOverrides {
            hatchery       = ./hatchery;
            hatchery-bench = ./hatchery-bench;
            hatchery-llvm  = ./hatchery-llvm;
            trustless-ffi  = ./trustless-ffi;
          })
          (hself: hsuper: {
            # llvm-ffi: follow nixpkgs pattern — LLVM = null, add .lib/.dev
            llvm-ffi = pkgs.haskell.lib.compose.addBuildDepends
              [ llvm.lib llvm.dev ]
              (hself.callHackage "llvm-ffi" "21.0.0.2" { LLVM = null; });
            llvm-tf = hself.callHackage "llvm-tf" "21.0" {};

            # hatchery needs HATCHERY_CC at TH compile time to build the fork server
            hatchery = pkgs.haskell.lib.compose.dontCheck (
              pkgs.haskell.lib.overrideCabal hsuper.hatchery (old: {
                preBuild = (old.preBuild or "") + ''
                  export HATCHERY_CC="${hatchery-cc}"
                '';
                buildTools = (old.buildTools or []) ++ [ musl-cc ];
              })
            );
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
          export HATCHERY_CC="${hatchery-cc}"
        '';
      };
    in {
      packages.${system} = {
        hatchery       = hsPkgs.hatchery;
        hatchery-bench = hsPkgs.hatchery-bench;
        hatchery-llvm  = hsPkgs.hatchery-llvm;
        trustless-ffi  = hsPkgs.trustless-ffi;
        default        = hsPkgs.hatchery;
      };
      devShells.${system}.default = haskellShell;
    };
}

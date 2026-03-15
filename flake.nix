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

      # Override haskellPackages with pinned llvm-ffi/llvm-tf versions
      hsPkgs = pkgs.haskellPackages.override {
        overrides = hself: hsuper: {
          llvm-ffi = hself.callHackage "llvm-ffi" "21.0.0.2" {};
          llvm-tf  = hself.callHackage "llvm-tf"  "21.0" {};
        };
      };

      # Dev shell with all Haskell deps pre-built
      haskellShell = hsPkgs.shellFor {
        packages = _: [];  # local packages built by cabal, not nix
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

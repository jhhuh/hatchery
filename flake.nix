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
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          pkgs.ghc
          pkgs.cabal-install
          musl-cc
          pkgs.llvmPackages_18.llvm
          pkgs.nasm
          pkgs.overmind
          pkgs.tmux
        ];

        shellHook = ''
          export MUSL_CC="${musl-cc}/bin/x86_64-unknown-linux-musl-gcc"
        '';
      };
    };
}

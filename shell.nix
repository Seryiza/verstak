{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = [
    pkgs.bubblewrap
    pkgs.codex
    pkgs.deadnix
    pkgs.fd
    pkgs.git
    pkgs.nil
    pkgs.nixfmt
    pkgs.nixpkgs-fmt
    pkgs.ripgrep
    pkgs.statix
  ];

  shellHook = ''
    echo "verstak nix-shell"
    echo "check:    nix flake check"
    echo "run:      nix run . -- codex"
    echo "gui:      nix run . -- -p gui codex"
  '';
}

{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    bubblewrap
    codex
    deadnix
    fd
    git
    nil
    nixfmt
    nixpkgs-fmt
    ripgrep
    statix
  ];

  shellHook = ''
    echo "verstak nix-shell"
    echo "check:    nix flake check"
    echo "gui:      nix run . -- /path/to/project"
    echo "headless: nix run .#headless -- /path/to/project"
  '';
}

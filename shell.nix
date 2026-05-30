{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShellNoCC {
  packages = import ./nix/dev-tools.nix { inherit pkgs; };

  shellHook = ''
    echo "verstak nix-shell"
    echo "Prefer flakes when available: nix develop"
    echo "check:    nix flake check -L"
    echo "run:      nix run . -- codex"
    echo "gui:      nix run . -- -p gui codex"
  '';
}

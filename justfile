set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
  just --list

# Format Nix and shell files.
fmt:
  nix fmt

# Run fast local linters.
lint:
  deadnix --fail .
  statix check .
  shellcheck nix/verstak-launcher.sh

# Run all configured pre-commit hooks against the repository.
hooks:
  pre-commit run --all-files

# Evaluate all flake outputs and checks without building checks.
eval:
  nix flake check --no-build

# Run the full flake check suite.
check:
  nix flake check -L

# Smoke-test the launcher help output.
smoke-help:
  nix run . -- --help

# Smoke-test a one-shot VM command.
smoke-one-shot:
  nix run . -- --one-shot true

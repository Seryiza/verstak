# Agent Workflow

This repo packages Verstak, a standalone QEMU-only Codex MicroVM. Keep changes focused on the flake, MicroVM module, VM instructions, skills, and documentation.

Useful commands:

- `nix flake check`
- `nix run . -- /path/to/project`
- `nix run .#gui -- /path/to/project`
- `nix run .#headless -- /path/to/project`

The VM mounts the selected project at `/workspace/project` and Codex state at `/home/codex/.codex`.

The default app server port is `4500`. Override launcher behavior with:

- `VERSTAK_STATE_DIR`
- `VERSTAK_APP_SERVER_PORT`
- `VERSTAK_APP_SERVER_HOST`
- `VERSTAK_MEM_MB`
- `VERSTAK_STORE_OVERLAY_MB`
- `VERSTAK_TMPFS_SIZE`
- `VERSTAK_MODE`

Inside the VM, Codex runs with full permissions inside the MicroVM boundary: no Codex sandbox and no approval prompts. Treat the MicroVM as the security boundary and review generated changes before committing them.

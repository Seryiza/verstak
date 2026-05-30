# Agent Workflow

This repo packages Verstak, a standalone QEMU-only Codex MicroVM. Keep changes focused on the flake, MicroVM module, VM instructions, skills, and documentation.

Useful commands:

- `nix flake check`
- `nix run . -- --help`
- `nix run . -- --allow-internet codex`
- `nix run . -- claude`
- `nix run . -- --allow-internet -p gui codex`
- `nix run . -- --one-shot ls -la`

The VM mounts the selected project at `/workspace/project`. Codex state lives at `/home/steve/.codex`; Claude state lives at `/home/steve/.claude`.

Networking is denied by default. `verstak codex` defaults to allowlisted OpenAI/Codex domain egress; use `--deny-network` to disable that or `--allow-internet` for general Internet egress. All network modes keep host/local/private ranges blocked. Codex is the only built-in profile with app-server forwarding, and forwarding is only enabled with `--allow-internet`. The default app server port is `4500`. Override launcher behavior with:

- `VERSTAK_STATE_DIR`
- `VERSTAK_APP_SERVER_PORT`
- `VERSTAK_APP_SERVER_HOST`
- `VERSTAK_MEM_MB`
- `VERSTAK_STORE_OVERLAY_MB`
- `VERSTAK_TMPFS_SIZE`
- `VERSTAK_MODE`
- `VERSTAK_NETWORK_MODE`

Inside the VM, Codex runs with full permissions inside the MicroVM boundary: no Codex sandbox and no approval prompts. Treat the MicroVM as the security boundary and review generated changes before committing them.

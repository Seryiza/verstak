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

Networking is denied by default. `verstak codex` defaults to rootless allowlisted OpenAI/Codex domain egress through QEMU restricted user networking and a host-side Go HTTP/TLS allowlist proxy. In allowlist mode, QEMU `restrict=on` prevents direct guest egress; the proxy permits only configured ports with an allowed HTTP Host or TLS SNI name and rejects blocked/private/reserved resolved target addresses before connecting. Use `--deny-network` to disable networking or `--allow-internet`/`VERSTAK_NETWORK_MODE=internet` for general Internet egress. General Internet mode uses in-guest nftables for best-effort host/local/private range blocking. Codex is the only built-in profile with app-server forwarding, and forwarding is enabled only in Internet mode. The default app server port is `4500`. Override launcher behavior with:

- `VERSTAK_STATE_DIR`
- `VERSTAK_APP_SERVER_PORT`
- `VERSTAK_APP_SERVER_HOST`
- `VERSTAK_MEM_MB`
- `VERSTAK_STORE_OVERLAY_MB`
- `VERSTAK_TMPFS_SIZE`
- `VERSTAK_MODE`
- `VERSTAK_NETWORK_MODE`

Inside the VM, Codex runs with full permissions inside the MicroVM boundary: no Codex sandbox and no approval prompts. Treat the MicroVM as the security boundary and review generated changes before committing them.

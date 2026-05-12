<p align="center">
  <img width="300" height="300" alt="verstak-logo" src="https://github.com/user-attachments/assets/d20c4eca-4ae9-4eee-ad0c-0d10e3cd4784" />
</p>

# verstak

Verstak is a small standalone Nix flake for running Codex inside a QEMU MicroVM.

The first argument is the project directory to mount. If omitted, Verstak uses the current working directory.

```sh
nix run . -- /path/to/project
nix run .#gui -- /path/to/project
nix run .#headless -- /path/to/project
```

The project is mounted inside the VM at `/workspace/project`. Codex home is `/home/codex`, with Codex configuration under `/home/codex/.codex`.
The writable Nix store overlay is backed by a MicroVM volume and defaults to 4096 MiB.
`/tmp` is an executable tmpfs capped at 1 GiB by default.

## Modes

`gui` starts a graphical QEMU MicroVM with Sway, foot, Firefox, screenshot helpers, keyboard and mouse helpers, and `codex-app-server` running in a terminal.

`headless` starts a non-graphical QEMU MicroVM and runs `codex-app-server` as a systemd service.

Both modes use QEMU user networking, 9p shares, and forward the Codex app-server port to the host.

## How I use it

- Emacs GUI debugging to resolve the "fix A, then fix B, then verify A wasn't broken by the B fix" loop
<img width="480" alt="image" src="https://github.com/user-attachments/assets/71a1e882-ccec-4c8c-a224-04d7b0835b4a" />

## Connection

The default app-server host URL is:

```sh
codex --dangerously-bypass-approvals-and-sandbox --remote ws://127.0.0.1:4500
```

The launcher prints the exact command before starting the VM.

## Environment

- `VERSTAK_STATE_DIR`: VM state directory. Defaults to `$HOME/.local/state/verstak/$project_name`.
- `VERSTAK_APP_SERVER_PORT`: forwarded app-server port. Defaults to `4500`.
- `VERSTAK_APP_SERVER_HOST`: host address used for port forwarding. Defaults to `127.0.0.1`.
- `VERSTAK_MEM_MB`: VM memory in megabytes. Defaults to `8192`.
- `VERSTAK_STORE_OVERLAY_MB`: writable Nix store overlay volume size in mebibytes. Defaults to `4096`.
- `VERSTAK_TMPFS_SIZE`: executable `/tmp` tmpfs size. Accepts values such as `1024M`, `1G`, or `50%`. Defaults to `1G`.
- `VERSTAK_MODE`: override the selected app mode with `gui` or `headless`.

## VM Helpers

GUI mode exposes these commands inside the VM:

- `vm-windows`
- `vm-focus`
- `vm-screenshot`
- `vm-key`
- `vm-type`
- `vm-click`
- `vm-move-mouse`

Headless mode does not install Sway, greetd, GUI applications, or GUI helper commands.

<p align="center">
  <img width="400" height="240" alt="verstak-logo" src="https://github.com/user-attachments/assets/0faeab58-3d4f-43aa-8347-f1c017982951" />
</p>

# verstak

Verstak is a small standalone Nix flake for running commands inside a QEMU MicroVM.

> [!WARNING]
> **This project is still under active development** and remains highly unstable. Some areas are still rough around the edges, and certain functionality may not yet behave reliably.

Use the public flake app:

```sh
nix run github:Seryiza/verstak -- [verstak-options] [command] [command-args...]
```

The usual local alias is:

```sh
alias verstak='nix run github:Seryiza/verstak --'
```

For a local clone of Verstak, use a `path:` flake ref:

```sh
alias verstak='nix run path:/absolute/path/to/verstak --'
```

Examples:

```sh
verstak codex
verstak claude
verstak ls -la
verstak --one-shot ls -la
verstak -p gui codex --model gpt-5.5
verstak -C ~/repo codex
verstak --one-shot claude --version
verstak -- ls --color=always
```

Verstak options must appear before the command. The first non-option token
starts the VM command, and all later arguments are passed through unchanged.
If no command is given, Verstak opens a Bash session.

The selected project is mounted inside the VM at `/workspace/project`. By
default Verstak mounts the current working directory; override that with
`-C, --directory`.

The writable Nix store overlay is backed by a MicroVM volume and defaults to 4096 MiB.
`/tmp` is an executable tmpfs capped at 1 GiB by default.

## Options

- `-p, --profile NAME`: add a built-in or flake-provided profile.
- `-C, --directory PATH`: directory to mount at `/workspace/project`.
- `-f, --flake REF`: extra flake ref or directory providing profiles.
- `--devshell [REF]`: run the command through `nix develop`. The default ref is `/workspace/project`; use `--devshell=REF` for an explicit ref.
- `--no-devshell`: disable devshell use.
- `--one-shot`, `--oneshot`: run the command non-interactively and power off when it exits.
- `--state-dir PATH`: override VM state dir.
- `--mem MB`: override memory.
- `--store-overlay MB`: override writable Nix store overlay size.
- `--tmpfs-size SIZE`: override `/tmp` tmpfs size.
- `-h, --help`: print help.

## Profiles

`headless` is the default profile. It starts a non-graphical QEMU MicroVM,
attaches a Bash session as `steve`, and runs the selected command once in
`/workspace/project` before leaving the shell open for more commands. Use
`--one-shot` to run the command as a non-interactive service and power off the
VM when it exits. From an interactive headless shell, run `verstak-poweroff` to
shut down the VM.

`gui` starts a graphical QEMU MicroVM with Sway, foot, Firefox, screenshot
helpers, and keyboard and mouse helpers. It opens the selected command in a
foot terminal in `/workspace/project`.

`codex` adds the Codex package, Codex config under `/home/steve/.codex`, auth
seeding from `$HOME/.codex/auth.json`, built-in VM instructions, and the GUI
skill when the GUI profile is also enabled. `verstak codex` automatically adds
the `codex` profile.

`verstak codex` preserves the original remote app-server behavior in both
headless and GUI modes: it runs `codex app-server` in the VM and forwards the
app-server port to the host.

`claude` adds the Claude Code package, Claude config under
`/home/steve/.claude`, built-in VM instructions in
`/home/steve/.claude/CLAUDE.md`, and auth/config seeding from host
`$HOME/.claude/.credentials.json`, `$HOME/.claude/settings.json`, and
`$HOME/.claude.json` when those files exist. `verstak claude` automatically
adds the `claude` profile. Claude runs as a local CLI inside the VM; it does not
start an app server, use a remote connection, or forward a port.

All profiles use QEMU user networking, 9p/virtiofs shares, and QEMU-only MicroVM
behavior.

## How I use it

- Emacs GUI debugging to resolve the "fix A, then fix B, then verify A wasn't broken by the B fix" loop
<img width="480" alt="image" src="https://github.com/user-attachments/assets/71a1e882-ccec-4c8c-a224-04d7b0835b4a" />

## Connection

Codex is the only built-in profile with app-server and remote mode support. For
`verstak codex`, the default app-server host URL is:

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
- `VERSTAK_MODE`: default mode when neither `gui` nor `headless` is selected. Accepts `gui` or `headless`.

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

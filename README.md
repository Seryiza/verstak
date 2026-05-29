<p align="center">
  <img width="400" height="240" alt="verstak-logo" src="https://github.com/user-attachments/assets/0faeab58-3d4f-43aa-8347-f1c017982951" />
</p>

> [!WARNING]
> **This project is still under active development** and remains highly unstable. Some areas are still rough around the edges, and certain functionality may not yet behave reliably.

# verstak

verstak is a Nix flake for safe running commands inside small virtual machines.

- ❄️ **NixOS-first**. Use your project-level flake.nix and any additional flakes inside [MicroVMs](https://github.com/microvm-nix/microvm.nix).
- 🤖 **AI sandbox**. Run your agents with full permissions, either in terminal or with desktop environment.
- 🐙 **Safe in different ways**. Block internet access, allow only whitelisted MCPs, and attach selected directories to the sandbox.

## Usage

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
verstak --allow-internet codex
verstak claude
verstak ls -la
verstak --one-shot ls -la
verstak --allow-internet -p gui codex --model gpt-5.5
verstak --allow-internet -C ~/repo codex
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
- `--deny-network`: disable all guest networking. This is the default.
- `--allow-internet`: enable guest Internet egress while blocking host, private, link-local, multicast, and other non-Internet destination ranges.
- `--state-dir PATH`: override VM state dir.
- `--mem MB`: override memory.
- `--store-overlay MB`: override writable Nix store overlay size.
- `--tmpfs-size SIZE`: override `/tmp` tmpfs size.
- `-h, --help`: print help.

## Profiles

`headless` is the default profile. It starts a non-graphical QEMU MicroVM and
attaches a Bash session as `steve`. If the selected command is not `bash`, it
runs that command once on the attached TTY and powers off the VM when it exits.
Use `--one-shot` to run the command as a non-interactive service instead. From
an interactive headless shell, run `verstak-poweroff` to shut down the VM.

`gui` starts a graphical QEMU MicroVM with Sway, foot, Firefox, screenshot
helpers, and keyboard and mouse helpers. It opens the selected command in a
foot terminal in `/workspace/project`.

`codex` adds the Codex package, Codex config under `/home/steve/.codex`, auth
seeding from `$HOME/.codex/auth.json`, built-in VM instructions, and the GUI
skill when the GUI profile is also enabled. `verstak codex` automatically adds
the `codex` profile.

`verstak --allow-internet codex` runs `codex app-server` in the VM and forwards
the app-server port to the host in both headless and GUI modes. Without
`--allow-internet`, the Codex profile is still installed but guest networking
and port forwarding remain disabled.

`claude` adds the Claude Code package, Claude config under
`/home/steve/.claude`, built-in VM instructions in
`/home/steve/.claude/CLAUDE.md`, and auth/config seeding from host
`$HOME/.claude/.credentials.json`, `$HOME/.claude/settings.json`, and
`$HOME/.claude.json` when those files exist. `verstak claude` automatically
adds the `claude` profile. Claude runs as a local CLI inside the VM; it does not
start an app server, use a remote connection, or forward a port.

All profiles use 9p/virtiofs shares and QEMU-only MicroVM behavior. Guest
networking is disabled by default; pass `--allow-internet` when a command needs
Internet access.

## Network policy

By default, and with `--deny-network`, Verstak removes guest network interfaces
and forwarded ports from the MicroVM.

With `--allow-internet`, Verstak enables QEMU user networking and an nftables
egress policy that permits Internet-bound TCP, UDP, and ICMP while dropping
non-Internet destinations such as `10.0.0.0/8`, `172.16.0.0/12`, `192.0.0.0/8`,
loopback, link-local, multicast, CGNAT, and related reserved ranges. Static
public DNS resolvers are used so QEMU's local DNS proxy is not required.

## How I use it

- Emacs GUI debugging to resolve the "fix A, then fix B, then verify A wasn't broken by the B fix" loop
<img width="480" alt="image" src="https://github.com/user-attachments/assets/71a1e882-ccec-4c8c-a224-04d7b0835b4a" />

## Connection

Codex is the only built-in profile with app-server and remote mode support. Since
networking is denied by default, use `verstak --allow-internet codex` for the
forwarded app-server. The default app-server host URL is:

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
- `VERSTAK_NETWORK_MODE`: guest network policy. Accepts `deny` or `internet`; defaults to `deny`.

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

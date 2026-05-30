<p align="center">
  <img width="400" height="240" alt="verstak-logo" src="https://github.com/user-attachments/assets/0faeab58-3d4f-43aa-8347-f1c017982951" />
</p>

> [!WARNING]
> **This project is still under active development** and remains highly unstable. Some areas are still rough around the edges, and certain functionality may not yet behave reliably.

# verstak

verstak is a Nix flake for safe running commands inside small virtual machines.

- ❄️ **NixOS-first**: use any flake.nix files inside [MicroVMs](https://github.com/microvm-nix/microvm.nix).
- 🤖 **AI Sandboxes**: run your agents with full permissions without affecting your main system.
- 👀 **TUI and GUI**: start virtual machines either in _terminal_ or with _desktop environment_.
- 🐙 **Safe in different ways**: block internet access, allow only whitelisted MCPs, and attach selected directories to the sandbox.

## Usage

You need only [Nix or NixOS](https://nixos.org/download).

The simplest way to use verstak is `nix run`:

```sh
nix run github:Seryiza/verstak -- [verstak-options] [command] [command-args...]

# or with cloned repository:
# nix run path:/home/your-username/code/verstak -- [verstak-options] [command] [command-args...]
```

I prefer to add it as shell alias:

```sh
alias verstak='nix run github:Seryiza/verstak -- '

# or with cloned repository:
# alias verstak='nix run path:/home/your-username/code/verstak -- '
```

Here are some examples:

### list directory

```sh
verstak ls -lh
```

```
total 72K
drwxr-xr-x 2 steve steve 4.0K May 29 18:55 agents
-rw-r--r-- 1 steve steve 1.3K May 29 18:55 AGENTS.md
-rw-r--r-- 1 steve steve 5.5K May 12 00:49 flake.lock
-rw-r--r-- 1 steve steve 3.3K May 25 09:32 flake.nix
drwxr-xr-x 3 steve steve 4.0K May 29 18:55 nix
-rw-r--r-- 1 steve steve 6.7K May 29 18:55 README.md
-rw-r--r-- 1 steve steve  408 May 25 09:32 shell.nix
drwxr-xr-x 3 steve steve 4.0K May 11 06:34 skills
```

> [!NOTE]
> By default verstak mounts the current working directory to `/workspace/project` inside the VM.

### ping

```sh
verstak ping google.com
```

```
ping: google.com: Name or service not known
```

> [!NOTE]
> By default verstak is started without any network access. If you want to allow internet, use `--allow-internet` parameter.


```sh
verstak --allow-internet ping google.com
```

```
PING google.com (142.251.223.110) 56(84) bytes of data.
64 bytes from tzdela-ar-in-f14.1e100.net (142.251.223.110): icmp_seq=1 ttl=255 time=454 ms
64 bytes from tzdela-ar-in-f14.1e100.net (142.251.223.110): icmp_seq=2 ttl=255 time=459 ms
64 bytes from tzdela-ar-in-f14.1e100.net (142.251.223.110): icmp_seq=3 ttl=255 time=457 ms
64 bytes from tzdela-ar-in-f14.1e100.net (142.251.223.110): icmp_seq=4 ttl=255 time=457 ms
64 bytes from tzdela-ar-in-f14.1e100.net (142.251.223.110): icmp_seq=5 ttl=255 time=454 ms
```

### codex

Finally, you can run interactive apps like `codex`:

```sh
verstak codex
```

```
╭──────────────────────────────────────────────╮
│ >_ OpenAI Codex (v0.130.0)                   │
│                                              │
│ model:       gpt-5.5 high   /model to change │
│ directory:   /workspace/project              │
│ permissions: YOLO mode                       │
╰──────────────────────────────────────────────╯

  Tip: Use /status to see the current model, approvals, and token usage.

› Improve documentation in @filename

  gpt-5.5 high · /workspace/project
```

> [!NOTE]
> verstak autodetects some commands and applies to them special logic. In case of `codex`, verstak provides your host `~/.codex/auth.json` credentials for automatic log-in.

## Options

The writable Nix store overlay is backed by a MicroVM volume and defaults to 4096 MiB.
`/tmp` is an executable tmpfs capped at 1 GiB by default.

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
- `VERSTAK_TTY_ROWS`, `VERSTAK_TTY_COLUMNS`: override the headless terminal size. Defaults to the host terminal size when available, otherwise `40x120`.
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

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

### ls: filesystem

> [!NOTE]
> By default verstak mounts the current working directory to `/workspace/project` inside the VM.

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

### ping: network access

> [!NOTE]
> By default verstak is started without any network access.

```sh
verstak ping google.com
```

```
ping: google.com: Name or service not known
```

> [!NOTE]
> If you want to allow internet, use `--allow-internet` parameter.

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

### codex: interactive apps

> [!NOTE]
> verstak autodetects some commands and applies to them special logic. In case of `codex`, verstak adds the codex profile, seeds your host `~/.codex/auth.json` credentials, and allows network access for OpenAI/Codex domains.


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

## Options

The writable Nix store overlay is backed by a MicroVM volume and defaults to 4096 MiB.
`/tmp` is an executable tmpfs capped at 1 GiB by default.

- `-p, --profile NAME`: add a built-in or flake-provided profile.
- `-C, --directory PATH`: directory to mount at `/workspace/project`.
- `-f, --flake REF`: extra flake ref or directory providing profiles.
- `--devshell [REF]`: run the command through `nix develop`. The default ref is `/workspace/project`; use `--devshell=REF` for an explicit ref.
- `--no-devshell`: disable devshell use.
- `--one-shot`, `--oneshot`: run the command non-interactively and power off when it exits.
- `--deny-network`: disable all guest networking. This is the default, except for auto-detected `verstak codex`.
- `--allow-internet`: enable guest Internet egress. Host/private range blocking is best-effort in this mode because it relies on guest firewall rules.
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
seeding from `$HOME/.codex/auth.json`, built-in VM instructions, OpenAI/Codex
network allowlist domains, and the GUI skill when the GUI profile is also
enabled. `verstak codex` automatically adds the `codex` profile and, unless a
network option/environment override was provided, uses allowlisted networking.

`verstak --allow-internet codex` runs `codex app-server` in the VM and forwards
the app-server port to the host in both headless and GUI modes using QEMU
user-mode `hostfwd`. Without `--allow-internet`, `verstak codex` runs the local
Codex CLI with only the OpenAI/Codex domain allowlist and no app-server port
forwarding. Pass `--deny-network` to disable networking entirely.

`claude` adds the Claude Code package, Claude config under
`/home/steve/.claude`, built-in VM instructions in
`/home/steve/.claude/CLAUDE.md`, and auth/config seeding from host
`$HOME/.claude/.credentials.json`, `$HOME/.claude/settings.json`, and
`$HOME/.claude.json` when those files exist. `verstak claude` automatically
adds the `claude` profile. Claude runs as a local CLI inside the VM; it does not
start an app server, use a remote connection, or forward a port.

All profiles use 9p/virtiofs shares and QEMU-only MicroVM behavior. Guest
networking is disabled by default; pass `--allow-internet` when a command needs
general Internet access.

## Network policy

By default, and with `--deny-network`, Verstak removes guest network interfaces
and forwarded ports from the MicroVM.

For network-enabled modes, Verstak uses rootless QEMU user networking; it does
not require `sudo` or host firewall changes.

With allowlisted networking, profiles/modules contribute
`verstak.network.allowedDomains`. Allowlist mode uses QEMU's `restrict=on` user
network so the guest cannot open direct outbound sockets.
Guest DNS maps allowed domains to an internal QEMU `guestfwd` endpoint, and a
host-side Go allowlist proxy permits only configured TCP ports (80 and 443 by
default) when the request's HTTP `Host` header or TLS SNI name matches an
allowed domain suffix. HTTP `Host` is accepted on any configured allowlist port
before the proxy falls back to TLS SNI, so custom HTTP ports such as 8080 work
when the domain is allowlisted. Before connecting, the proxy resolves the target
host from the host side and rejects private, loopback, link-local, multicast,
documentation, reserved, and other configured blocked ranges. `verstak codex`
uses this mode by default for OpenAI/Codex domains.

> [!NOTE]
> Allowlist mode is intended for HTTPS/HTTP agent traffic. It enforces domain
> and resolved-address policy outside the guest, but it is not a transparent
> arbitrary-protocol firewall. Protocols without HTTP Host or TLS SNI are denied
> by the proxy.

With Internet mode (`--allow-internet` or `VERSTAK_NETWORK_MODE=internet`),
Verstak enables unrestricted QEMU user networking and an in-guest nftables
policy that tries to block host, private, link-local, multicast, CGNAT, and
other reserved ranges. This mode is convenient, but the range block is
best-effort because guest root can alter guest nftables. Prefer allowlist mode
when you want restricted egress without sudo.

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
- `VERSTAK_NETWORK_MODE`: guest network policy. Accepts `deny`, `allowlist`, or `internet`; defaults to `deny` (`verstak codex` defaults to `allowlist`).

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

## Development

Enter the reproducible development shell with:

```sh
nix develop
```

Optional automatic activation uses `direnv`/`nix-direnv`:

```sh
direnv allow
```

Common development commands are available through `just`:

```sh
just --list
just fmt      # nix fmt
just lint     # deadnix, statix, shellcheck
just check    # nix flake check -L
```

`nix flake check` runs formatting, pre-commit hooks, deadnix, statix,
shellcheck, and profile evaluation checks for headless, GUI, Codex, and Claude
configurations.

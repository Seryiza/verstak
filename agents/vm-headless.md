# Verstak Headless Instructions

This VM is running the headless profile. Sway, greetd, graphical applications, and GUI helper commands are intentionally unavailable.

Use terminal-first workflows from `/workspace/project`. Ordinary headless commands run in an interactive Bash session unless the host used `--one-shot`.

When the VM was launched with `verstak codex`, `codex app-server` runs as a systemd service and is forwarded to the host through QEMU user networking.

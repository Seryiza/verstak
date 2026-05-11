# Verstak Headless Instructions

This VM is running the headless profile. Sway, greetd, graphical applications, and GUI helper commands are intentionally unavailable.

Use terminal-first workflows from `/workspace/project`. `codex-app-server` runs as a systemd service and is forwarded to the host through QEMU user networking.

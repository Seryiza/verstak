# VM GUI Skill

Use this skill when you need to inspect or control GUI applications inside the Verstak GUI MicroVM.

## Workflow

1. Run `vm-windows` to see visible windows, focus state, titles, and geometry.
2. Use `vm-focus <query>` to focus the target window by app id, class, or title fragment.
3. Use `vm-key` for keyboard input and shortcuts.
4. Use `vm-type` only for literal text entry.
5. Use `vm-screenshot` to inspect the full display, or `vm-screenshot <query>` to capture one matching window.
6. Use `vm-move-mouse` and `vm-click` only when keyboard or Sway control is not enough.

Screenshots are saved under `/home/codex/screenshots`.

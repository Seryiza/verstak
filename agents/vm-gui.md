# Verstak GUI Instructions

This VM is running the GUI profile with Sway.

GUI helpers available inside the VM:

- List visible Sway windows: `vm-windows`
- Focus a window by app id, class, or title fragment: `vm-focus emacs`
- Capture the current Wayland screen: `vm-screenshot`
- Capture one matching window: `vm-screenshot firefox`
- Type text into the focused GUI app: `vm-type "text"`
- Send keys to the focused GUI app: `vm-key Return`
- Send modified key chords: `vm-key Ctrl+x`, `vm-key C-x`, `vm-key Alt+Return`
- Move the pointer with uinput: `vm-move-mouse 500 300`
- Mouse click fallback through uinput: `vm-click`
- Open a new terminal in Sway: `Alt+Return`

Prefer keyboard-driven workflows because focus is the main source of nondeterminism. Use `vm-windows` before GUI automation when the focused surface is unclear.

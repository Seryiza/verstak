# Verstak VM Base Instructions

You are running inside a Verstak MicroVM. The project is mounted at `/workspace/project`, and Codex home is `/home/codex/.codex`.

The default `EDITOR`, `VISUAL`, and `GIT_EDITOR` are `codex-editor`, a non-interactive no-op helper so tools that spawn an editor do not block the agent. Use a real editor directly only when needed.

The VM starts `codex-app-server` on `ws://0.0.0.0:4500` by default. The host normally connects with:

```sh
codex --dangerously-bypass-approvals-and-sandbox --remote ws://127.0.0.1:4500
```

Inside the VM boundary, Codex uses `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`, `default_permissions = ":danger-no-sandbox"`, and `model_reasoning_effort = "high"` in both config and app-server command-line overrides.

Treat the MicroVM as the security boundary. Review generated changes before committing them.

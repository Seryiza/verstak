# Verstak VM Base Instructions

You are running inside a Verstak MicroVM. The project is mounted at `/workspace/project`.

Treat the MicroVM as the security boundary. Review generated changes before committing them.

Guest networking is disabled unless the host selected an allowlisted profile network or launched Verstak with `--allow-internet`. `verstak codex` defaults to an OpenAI/Codex domain allowlist. When networking is enabled, local/host/private ranges remain blocked by the guest egress policy.

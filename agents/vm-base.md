# Verstak VM Base Instructions

You are running inside a Verstak MicroVM. The project is mounted at `/workspace/project`.

Treat the MicroVM as the security boundary. Review generated changes before committing them.

Guest networking is disabled unless the host selected an allowlisted profile network or launched Verstak with `--allow-internet`. `verstak codex` defaults to an OpenAI/Codex domain allowlist. In allowlist mode, QEMU restricted networking prevents direct guest egress while the host-side Go proxy permits only configured HTTP Host/TLS SNI traffic to allowed domains and rejects blocked resolved addresses. In Internet mode, local/host/private ranges are blocked by the guest egress policy on a best-effort basis.

Some sessions may expose selected host tools such as `git` or `gh` as normal commands. These are host-program proxy stubs, not guest-side permission grants. If a host-program invocation is denied, treat the stderr reason as policy: do not try to bypass it by editing stubs or using sudo. Host-program cwd mapping only works under `/workspace/project`, and audit logs record invocation metadata without stdout/stderr transcripts.

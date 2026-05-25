{ config, lib, llmAgents ? null, pkgs }:

let
  cfg = config.verstak;
  codexConfigHome = "${cfg.internal.vmUserHome}/.codex";
  codexAuthSeedMount = "/run/verstak-codex-auth";
  codexAppServerListen = "ws://0.0.0.0:${toString cfg.codex.appServer.port}";
  codexAppServerRemote = "ws://${cfg.codex.appServer.hostAddress}:${
      toString cfg.codex.appServer.port
    }";

  codexPackage =
    if llmAgents == null then pkgs.codex else pkgs.llm-agents.codex;

  codexEditor = pkgs.writeShellScriptBin "codex-editor" ''
    set -euo pipefail
    exit 0
  '';

  seedCodexAuth = pkgs.writeShellScriptBin "verstak-seed-codex-auth" ''
    set -euo pipefail

    install -d -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 700 ${codexConfigHome}
    if [ -f ${codexAuthSeedMount}/auth.json ]; then
      install -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 600 ${codexAuthSeedMount}/auth.json ${codexConfigHome}/auth.json
    else
      rm -f ${codexConfigHome}/auth.json
    fi

    install -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 600 /etc/codex/config.toml ${codexConfigHome}/config.toml
    install -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 600 /etc/codex/AGENTS.md ${codexConfigHome}/AGENTS.md
    ${lib.optionalString cfg.gui.enable ''
      install -d -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 700 ${codexConfigHome}/skills/vm-gui
      install -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 600 /etc/codex/skills/vm-gui/SKILL.md ${codexConfigHome}/skills/vm-gui/SKILL.md
    ''}
  '';

  codexAppServer = pkgs.writeShellScriptBin "codex-app-server" ''
    set -euo pipefail
    cd ${cfg.projectMount}
    exec ${codexPackage}/bin/codex app-server \
      --listen ${codexAppServerListen} \
      -c sandbox_mode='"danger-full-access"' \
      -c approval_policy='"never"' \
      -c default_permissions='":danger-no-sandbox"' \
      -c model_reasoning_effort='"high"' \
      -c shell_environment_policy.inherit='"all"' \
      "$@"
  '';
in {
  inherit codexAppServer codexAppServerListen codexAppServerRemote
    codexAuthSeedMount codexConfigHome codexEditor codexPackage seedCodexAuth;

  packages = [ codexPackage codexAppServer codexEditor ];
}

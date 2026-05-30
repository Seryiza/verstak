{
  config,
  lib,
  llmAgents ? null,
  pkgs,
}:

let
  cfg = config.verstak;
  claudeConfigHome = "${cfg.internal.vmUserHome}/.claude";
  claudeGlobalConfig = "${cfg.internal.vmUserHome}/.claude.json";
  claudeAuthSeedMount = "/run/verstak-claude-auth";

  claudePackage =
    if llmAgents == null then
      throw "the claude profile requires the llm-agents flake input"
    else
      pkgs.llm-agents.claude-code;

  seedClaudeAuth = pkgs.writeShellScriptBin "verstak-seed-claude-auth" ''
    set -euo pipefail

    install -d -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 700 ${claudeConfigHome}

    if [ -f ${claudeAuthSeedMount}/.credentials.json ]; then
      install -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 600 ${claudeAuthSeedMount}/.credentials.json ${claudeConfigHome}/.credentials.json
    fi

    global_tmp="$(${pkgs.coreutils}/bin/mktemp)"
    global_filter='.[0] * .[1]
      | .theme = "light-daltonized"
      | .bypassPermissionsModeAccepted = true
      | .projects[$project].hasTrustDialogAccepted = true
      | .projects[$project].hasCompletedProjectOnboarding = true
      | .projects[$project].projectOnboardingSeenCount = 1'
    if [ -f ${claudeAuthSeedMount}/.claude.json ]; then
      ${pkgs.jq}/bin/jq --arg project ${lib.escapeShellArg cfg.projectMount} -s "$global_filter" /etc/claude/claude.json ${claudeAuthSeedMount}/.claude.json > "$global_tmp"
    elif [ -f ${claudeGlobalConfig} ]; then
      ${pkgs.jq}/bin/jq --arg project ${lib.escapeShellArg cfg.projectMount} -s "$global_filter" /etc/claude/claude.json ${claudeGlobalConfig} > "$global_tmp"
    else
      ${pkgs.jq}/bin/jq --arg project ${lib.escapeShellArg cfg.projectMount} '.theme = "light-daltonized"
        | .bypassPermissionsModeAccepted = true
        | .projects[$project].hasTrustDialogAccepted = true
        | .projects[$project].hasCompletedProjectOnboarding = true
        | .projects[$project].projectOnboardingSeenCount = 1' /etc/claude/claude.json > "$global_tmp"
    fi
    install -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 600 "$global_tmp" ${claudeGlobalConfig}
    rm -f "$global_tmp"

    tmp="$(${pkgs.coreutils}/bin/mktemp)"
    if [ -f ${claudeAuthSeedMount}/settings.json ]; then
      ${pkgs.jq}/bin/jq -s '((.[0] // {}) | del(.theme, .skipAutoPermissionPrompt)) * .[1]' ${claudeAuthSeedMount}/settings.json /etc/claude/settings.json > "$tmp"
    elif [ -f ${claudeConfigHome}/settings.json ]; then
      ${pkgs.jq}/bin/jq -s '((.[0] // {}) | del(.theme, .skipAutoPermissionPrompt)) * .[1]' ${claudeConfigHome}/settings.json /etc/claude/settings.json > "$tmp"
    else
      ${pkgs.coreutils}/bin/cp /etc/claude/settings.json "$tmp"
    fi
    install -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 600 "$tmp" ${claudeConfigHome}/settings.json
    rm -f "$tmp"

    install -o ${cfg.vm.user} -g ${cfg.internal.vmPrimaryGroup} -m 600 /etc/claude/CLAUDE.md ${claudeConfigHome}/CLAUDE.md
  '';
in
{
  inherit
    claudeAuthSeedMount
    claudeConfigHome
    claudeGlobalConfig
    claudePackage
    seedClaudeAuth
    ;

  packages = [ claudePackage ];
}

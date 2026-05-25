{ config, lib, llmAgents ? null, pkgs, ... }:

let
  cfg = config.verstak;
  agentInstructions = import ../lib/agent-instructions.nix { inherit config; };
  codexTools = import ../tools/codex.nix { inherit config lib llmAgents pkgs; };
  agentText = agentInstructions.mkAgentText ''

    Codex home is ${codexTools.codexConfigHome}.

    The default EDITOR, VISUAL, and GIT_EDITOR are codex-editor, a
    non-interactive no-op helper so tools that spawn an editor do not block
    the agent. Use a real editor directly only when needed.

    When launched with verstak codex, the VM starts codex app-server on
    ${codexTools.codexAppServerListen} by default. The host normally
    connects with:

        codex --dangerously-bypass-approvals-and-sandbox --remote ${codexTools.codexAppServerRemote}

    Inside the VM boundary, Codex uses approval_policy = "never",
    sandbox_mode = "danger-full-access", default_permissions =
    ":danger-no-sandbox", and model_reasoning_effort = "high" in both
    config and app-server command-line overrides.
  '';
in {
  config = lib.mkIf cfg.codex.enable {
    environment.systemPackages = codexTools.packages;

    environment.sessionVariables = {
      CODEX_HOME = codexTools.codexConfigHome;
      EDITOR = "codex-editor";
      GIT_EDITOR = "codex-editor";
      HUMAN_EDITOR = "nano";
      VERSTAK_CODEX_APP_SERVER_LISTEN = codexTools.codexAppServerListen;
      VERSTAK_CODEX_REMOTE_URL = codexTools.codexAppServerRemote;
      VISUAL = "codex-editor";
    };

    environment.etc = {
      "codex/config.toml".text = ''
        cli_auth_credentials_store = "file"
        sandbox_mode = "danger-full-access"
        approval_policy = "never"
        default_permissions = ":danger-no-sandbox"
        model_reasoning_effort = "high"

        [shell_environment_policy]
        inherit = "all"

        [projects."${cfg.projectMount}"]
        trust_level = "trusted"
      '';

      "codex/AGENTS.md".text = agentText;
    } // lib.optionalAttrs cfg.gui.enable {
      "codex/skills/vm-gui/SKILL.md".source = cfg.docs.guiSkillPath;
    };

    systemd.services.verstak-codex-auth = {
      description = "Copy host Codex auth into guest Codex home";
      after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
      wants = [ "systemd-tmpfiles-setup.service" ];
      before = [ "verstak-command.service" "verstak-shell.service" ]
        ++ lib.optionals cfg.gui.enable [ "greetd.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${codexTools.seedCodexAuth}/bin/verstak-seed-codex-auth";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.internal.vmUserHome}/.codex 0700 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
      "d /tmp/codex-cache 0700 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
    ] ++ lib.optionals cfg.gui.enable [
      "d ${cfg.internal.vmUserHome}/.codex/skills 0700 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
      "d ${cfg.internal.vmUserHome}/.codex/skills/vm-gui 0700 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
      "d ${cfg.internal.vmUserHome}/screenshots 0755 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
    ];
  };
}

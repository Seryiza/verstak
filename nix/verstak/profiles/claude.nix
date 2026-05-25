{ config, lib, llmAgents ? null, pkgs, ... }:

let
  cfg = config.verstak;
  agentInstructions = import ../lib/agent-instructions.nix { inherit config; };
  claudeTools =
    import ../tools/claude.nix { inherit config lib llmAgents pkgs; };
  agentText = agentInstructions.mkAgentText ''

    Claude Code runs locally inside the MicroVM. There is no app server,
    remote connection, or forwarded Claude port.

    Host auth and configuration are seeded from ~/.claude/.credentials.json,
    ~/.claude/settings.json, and ~/.claude.json when those files exist.

    Treat the MicroVM as the security boundary. Review generated changes
    before committing them.
  '';
in {
  config = lib.mkIf cfg.claude.enable {
    environment.systemPackages = claudeTools.packages;

    environment.etc = {
      "claude/settings.json".text = builtins.toJSON {
        skipDangerousModePermissionPrompt = true;
        permissions = { defaultMode = "bypassPermissions"; };
      };

      "claude/claude.json".text =
        builtins.toJSON { theme = "light-daltonized"; };

      "claude/CLAUDE.md".text = agentText;

      "claude-code/managed-settings.json".text = builtins.toJSON {
        skipDangerousModePermissionPrompt = true;
        permissions = { defaultMode = "bypassPermissions"; };
      };
    };

    systemd.services.verstak-claude-auth = {
      description = "Copy host Claude auth into guest Claude home";
      after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
      wants = [ "systemd-tmpfiles-setup.service" ];
      before = [ "verstak-command.service" "verstak-shell.service" ]
        ++ lib.optionals cfg.gui.enable [ "greetd.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.coreutils pkgs.jq ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart =
          "${claudeTools.seedClaudeAuth}/bin/verstak-seed-claude-auth";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.internal.vmUserHome}/.claude 0700 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
    ];
  };
}

{ config, lib, llmAgents ? null, pkgs, ... }:

let
  cfg = config.verstak;
  baseTools = import ../tools/base.nix { inherit config lib llmAgents pkgs; };
  claudeTools =
    import ../tools/claude.nix { inherit config lib llmAgents pkgs; };
  codexTools = import ../tools/codex.nix { inherit config lib llmAgents pkgs; };
  servicePath = baseTools.packages
    ++ lib.optionals cfg.codex.enable codexTools.packages
    ++ lib.optionals cfg.claude.enable claudeTools.packages;
  serviceEnvironment = {
    HOME = cfg.internal.vmUserHome;
    USER = cfg.vm.user;
    LOGNAME = cfg.vm.user;
    VERSTAK_MODE = cfg.internal.mode;
    VERSTAK_PROJECT_MOUNT = cfg.projectMount;
  } // lib.optionalAttrs cfg.codex.enable {
    CODEX_HOME = codexTools.codexConfigHome;
    EDITOR = "codex-editor";
    GIT_EDITOR = "codex-editor";
    VISUAL = "codex-editor";
    XDG_CACHE_HOME = "/tmp/codex-cache";
  };
  codexAuthDependency =
    lib.optionals cfg.codex.enable [ "verstak-codex-auth.service" ];
  claudeAuthDependency =
    lib.optionals cfg.claude.enable [ "verstak-claude-auth.service" ];
  authDependencies = codexAuthDependency ++ claudeAuthDependency;
in {
  boot.consoleLogLevel = lib.mkIf (!cfg.gui.enable) 0;
  systemd.services."serial-getty@ttyS0".enable =
    lib.mkIf (!cfg.gui.enable) false;

  systemd.services.verstak-shell = lib.mkIf ((!cfg.gui.enable)
    && (!cfg.command.oneShot) && (!baseTools.isHeadlessCodexAppServer)) {
      description = "Verstak interactive shell";
      after = [ "network-online.target" "systemd-tmpfiles-setup.service" ]
        ++ authDependencies;
      wants = [ "network-online.target" "systemd-tmpfiles-setup.service" ]
        ++ authDependencies;
      wantedBy = [ "multi-user.target" ];
      path = servicePath;
      environment = serviceEnvironment;
      unitConfig = lib.optionalAttrs baseTools.runInitialCommand {
        SuccessAction = "poweroff";
        FailureAction = "poweroff";
      };
      serviceConfig = {
        User = cfg.vm.user;
        Group = cfg.internal.vmPrimaryGroup;
        WorkingDirectory = cfg.projectMount;
        ExecStart = "${baseTools.interactiveShell}/bin/verstak-shell";
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = "/dev/ttyS0";
        TTYReset = true;
        TTYVHangup = false;
      } // lib.optionalAttrs (!baseTools.runInitialCommand) {
        Restart = "always";
        RestartSec = "0";
      };
    };

  systemd.services.verstak-command = lib.mkIf ((!cfg.gui.enable)
    && (cfg.command.oneShot || baseTools.isHeadlessCodexAppServer)) {
      description = "Verstak command";
      after = [ "network-online.target" "systemd-tmpfiles-setup.service" ]
        ++ authDependencies;
      wants = [ "network-online.target" "systemd-tmpfiles-setup.service" ]
        ++ authDependencies;
      wantedBy = [ "multi-user.target" ];
      path = servicePath;
      environment = serviceEnvironment;
      unitConfig = lib.optionalAttrs cfg.command.oneShot {
        SuccessAction = "poweroff";
        FailureAction = "poweroff";
      };
      serviceConfig = {
        User = cfg.vm.user;
        Group = cfg.internal.vmPrimaryGroup;
        WorkingDirectory = cfg.projectMount;
        ExecStart = "${baseTools.runCommand}/bin/verstak-run-command";
        StandardOutput =
          if cfg.command.oneShot then "tty" else "journal+console";
        StandardError =
          if cfg.command.oneShot then "tty" else "journal+console";
      } // lib.optionalAttrs baseTools.isHeadlessCodexAppServer {
        Restart = "on-failure";
        RestartSec = "2s";
      } // lib.optionalAttrs cfg.command.oneShot {
        StandardInput = "tty";
        TTYPath = "/dev/ttyS0";
        TTYReset = true;
        TTYVHangup = true;
      };
    };
}

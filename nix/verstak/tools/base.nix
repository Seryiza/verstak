{ config, lib, llmAgents ? null, pkgs }:

let
  cfg = config.verstak;
  codexTools = import ./codex.nix { inherit config lib llmAgents pkgs; };
  userLocalBin = "${cfg.internal.vmUserHome}/.local/bin";
  basePath =
    "${userLocalBin}:/run/wrappers/bin:/run/current-system/sw/bin:${pkgs.coreutils}/bin:${pkgs.bashInteractive}/bin:${pkgs.nix}/bin:$PATH";
  isCodexCommand = cfg.codex.enable && cfg.command.argv != [ ]
    && builtins.head cfg.command.argv == "codex";
  isCodexAppServer = (cfg.network.mode == "internet") && (!cfg.command.oneShot)
    && isCodexCommand;
  isHeadlessCodexAppServer = (!cfg.gui.enable) && isCodexAppServer;
  effectiveCommand = if isCodexAppServer then
    [ "${codexTools.codexAppServer}/bin/codex-app-server" ]
    ++ lib.tail cfg.command.argv
  else
    cfg.command.argv;

  runCommand = pkgs.writeShellScriptBin "verstak-run-command" ''
    set -euo pipefail
    cd ${cfg.projectMount}
    export HOME=${cfg.internal.vmUserHome}
    export USER=${cfg.vm.user}
    export LOGNAME=${cfg.vm.user}
    export PATH=${basePath}
    ${if cfg.command.useDevshell then ''
      exec ${pkgs.nix}/bin/nix develop ${
        lib.escapeShellArg cfg.command.devshellRef
      } --command ${lib.escapeShellArgs effectiveCommand}
    '' else ''
      exec ${lib.escapeShellArgs effectiveCommand}
    ''}
  '';

  runInitialCommand = cfg.command.argv != [ ] && cfg.command.argv != [ "bash" ];

  verstakPoweroff = pkgs.writeShellScriptBin "verstak-poweroff" ''
    set -euo pipefail

    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      exec /run/wrappers/bin/sudo -n ${pkgs.systemd}/bin/systemctl \
        --no-wall start poweroff.target --job-mode=replace-irreversibly
    fi

    exec ${pkgs.systemd}/bin/systemctl \
      --no-wall start poweroff.target --job-mode=replace-irreversibly
  '';

  interactiveCommand = lib.optionalString runInitialCommand ''
    printf '\n+ %s\n' ${
      lib.escapeShellArg (lib.escapeShellArgs cfg.command.argv)
    }
    set +e
    ${lib.escapeShellArgs cfg.command.argv}
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      printf 'Command exited with status %s\n' "$status"
    fi
    printf '\n'
  '';

  interactiveBashRc = pkgs.writeText "verstak-bashrc" ''
    export HOME=${cfg.internal.vmUserHome}
    export USER=${cfg.vm.user}
    export LOGNAME=${cfg.vm.user}
    export PATH=${basePath}
    export PS1='\u@verstak:\w\$ '
    alias poweroff=verstak-poweroff
    alias shutdown=verstak-poweroff
    cd ${cfg.projectMount}

    if [ -z "''${VERSTAK_INTERACTIVE_BOOTSTRAPPED:-}" ]; then
      export VERSTAK_INTERACTIVE_BOOTSTRAPPED=1
      printf '\nVerstak shell: %s\n' ${lib.escapeShellArg cfg.projectMount}
      ${interactiveCommand}
    fi
  '';

  interactiveShell = pkgs.writeShellScriptBin "verstak-shell" ''
    set -euo pipefail
    cd ${cfg.projectMount}
    export HOME=${cfg.internal.vmUserHome}
    export USER=${cfg.vm.user}
    export LOGNAME=${cfg.vm.user}
    export PATH=${basePath}
    printf '\nVerstak headless shell\n'
    printf 'Project: %s. Power off with: verstak-poweroff\n' ${
      lib.escapeShellArg cfg.projectMount
    }
    ${if cfg.command.useDevshell then ''
      exec ${pkgs.nix}/bin/nix develop ${
        lib.escapeShellArg cfg.command.devshellRef
      } --command ${pkgs.bashInteractive}/bin/bash --rcfile ${interactiveBashRc} -i
    '' else ''
      exec ${pkgs.bashInteractive}/bin/bash --rcfile ${interactiveBashRc} -i
    ''}
  '';
in {
  inherit effectiveCommand interactiveShell isCodexAppServer
    isHeadlessCodexAppServer runCommand verstakPoweroff;

  packages = [
    pkgs.bashInteractive
    pkgs.bubblewrap
    pkgs.coreutils
    pkgs.curl
    pkgs.direnv
    pkgs.fd
    pkgs.git
    pkgs.jq
    pkgs.nano
    pkgs.nil
    pkgs.nix-direnv
    pkgs.nixfmt
    pkgs.nixpkgs-fmt
    pkgs.pciutils
    pkgs.ripgrep
    runCommand
    pkgs.statix
    verstakPoweroff
  ];
}

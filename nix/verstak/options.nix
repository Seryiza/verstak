{ config, lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;
  pathLike = types.oneOf [ types.path types.str ];
in {
  options.verstak = {
    profiles = mkOption {
      type = types.listOf types.str;
      default = [ "headless" ];
      description = "Selected Verstak profile names.";
    };

    projectRoot = mkOption {
      type = pathLike;
      description = "Host project path mounted into the guest.";
    };

    stateVersion = mkOption {
      type = types.str;
      default = "26.05";
      description = "NixOS state version used by the guest.";
    };

    projectName = mkOption {
      type = types.str;
      default = "project";
      description = "Project name used by launcher state paths.";
    };

    projectMount = mkOption {
      type = types.str;
      default = "/workspace/project";
      description = "Guest mount path for the project.";
    };

    stateDir = mkOption {
      type = types.str;
      description =
        "Host state directory for guest home and writable store overlay.";
    };

    vm = {
      user = mkOption {
        type = types.str;
        default = "steve";
        description = "Guest user name.";
      };

      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Guest primary group name. Defaults to the user name.";
      };

      uid = mkOption {
        type = types.int;
        default = 1000;
        description = "Guest user id.";
      };

      gid = mkOption {
        type = types.int;
        default = 1000;
        description = "Guest primary group id.";
      };

      home = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Guest home directory. Defaults to /home/<user>.";
      };
    };

    gui.enable = mkEnableOption "the Sway GUI profile";

    codex = {
      enable = mkEnableOption "Codex CLI integration";

      appServer = {
        port = mkOption {
          type = types.port;
          default = 4500;
          description = "Codex app-server TCP port.";
        };

        hostAddress = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description =
            "Host address used for forwarded Codex app-server access.";
        };
      };
    };

    command = {
      argv = mkOption {
        type = types.listOf types.str;
        default = [ "bash" ];
        description = "Command argv executed in the guest.";
      };

      useDevshell = mkOption {
        type = types.bool;
        default = false;
        description = "Run commands through nix develop.";
      };

      devshellRef = mkOption {
        type = types.str;
        default = config.verstak.projectMount;
        defaultText = lib.literalExpression "config.verstak.projectMount";
        description = "Flake reference used for nix develop.";
      };

      oneShot = mkOption {
        type = types.bool;
        default = false;
        description = "Power off after the command exits.";
      };
    };

    resources = {
      memoryMb = mkOption {
        type = types.int;
        default = 8192;
        description = "Guest memory in MiB.";
      };

      storeOverlaySizeMb = mkOption {
        type = types.int;
        default = 4096;
        description = "Writable Nix store overlay size in MiB.";
      };

      tmpfsSize = mkOption {
        type = types.str;
        default = "1G";
        description = "Guest /tmp tmpfs size.";
      };
    };

    internal = {
      mode = mkOption {
        type = types.enum [ "headless" "gui" ];
        default = if config.verstak.gui.enable then "gui" else "headless";
        internal = true;
        description = "Derived guest mode.";
      };

      vmPrimaryGroup = mkOption {
        type = types.str;
        default = if config.verstak.vm.group == null then
          config.verstak.vm.user
        else
          config.verstak.vm.group;
        internal = true;
        description = "Derived guest primary group.";
      };

      vmUserHome = mkOption {
        type = types.str;
        default = if config.verstak.vm.home == null then
          "/home/${config.verstak.vm.user}"
        else
          config.verstak.vm.home;
        internal = true;
        description = "Derived guest home directory.";
      };
    };

    docs = {
      agentBasePath = mkOption {
        type = types.path;
        default = ../../agents/vm-base.md;
        description = "Base AGENTS.md source path.";
      };

      agentGuiPath = mkOption {
        type = types.path;
        default = ../../agents/vm-gui.md;
        description = "GUI AGENTS.md source path.";
      };

      agentHeadlessPath = mkOption {
        type = types.path;
        default = ../../agents/vm-headless.md;
        description = "Headless AGENTS.md source path.";
      };

      guiSkillPath = mkOption {
        type = types.path;
        default = ../../skills/vm-gui/SKILL.md;
        description = "GUI skill source path.";
      };
    };
  };
}

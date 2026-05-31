{
  config,
  lib,
  llmAgents ? null,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkOption types;
  pathLike = types.oneOf [
    types.path
    types.str
  ];
in
{
  options.verstak = {
    mode = mkOption {
      type = types.enum [
        "headless"
        "gui"
      ];
      default = "headless";
      description = "Verstak display and runner mode.";
    };

    profiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Selected Verstak agent/profile names, excluding the display mode.";
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
      description = "Host state directory for guest home and writable store overlay.";
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

      passwordlessSudo = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the guest user can run sudo without a password. This is
          convenient for agent workflows. Network modes that rely on guest
          firewall rules, such as Internet mode's host/private range blocking,
          are best-effort because guest root can alter nftables.
        '';
      };
    };

    gui.enable = mkEnableOption "the Sway GUI mode";

    codex = {
      enable = mkEnableOption "Codex CLI integration";

      package = mkOption {
        type = types.package;
        default = if llmAgents == null then pkgs.codex else pkgs.llm-agents.codex;
        defaultText = lib.literalExpression (
          if llmAgents == null then "pkgs.codex" else "pkgs.llm-agents.codex"
        );
        description = "Codex CLI package used by the Codex integration.";
      };

      appServer = {
        port = mkOption {
          type = types.port;
          default = 4500;
          description = "Codex app-server TCP port.";
        };

        hostAddress = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description = "Host address used for forwarded Codex app-server access.";
        };
      };
    };

    claude = {
      enable = mkEnableOption "Claude Code CLI integration";

      package = mkOption {
        type = types.nullOr types.package;
        default = if llmAgents == null then null else pkgs.llm-agents.claude-code;
        defaultText = lib.literalExpression "pkgs.llm-agents.claude-code";
        description = ''
          Claude Code package used by the Claude integration. Defaults to null
          when the llm-agents flake input is unavailable; set this option when
          using the Claude profile without llm-agents.
        '';
      };
    };

    network = {
      mode = mkOption {
        type = types.enum [
          "deny"
          "allowlist"
          "internet"
        ];
        default = "deny";
        description = ''
          Guest network policy. "deny" removes guest network interfaces and
          forwarded ports. "allowlist" enables rootless QEMU restricted user
          networking with a host-side domain allowlist proxy. "internet"
          enables QEMU user networking with an in-guest egress firewall that
          best-effort blocks host, private, link-local, multicast, and other
          non-Internet destination ranges.
        '';
      };

      allowedDomains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Domain suffixes allowed when network.mode is "allowlist". Profiles
          can extend this list; allowlist mode maps these domains to a
          restricted QEMU guest-forward endpoint and the host-side Go proxy
          permits only matching HTTP Host/TLS SNI names. The proxy resolves
          matching hosts outside the guest and rejects blocked/private/reserved
          target addresses before connecting.
        '';
      };

      allowedTCPPorts = mkOption {
        type = types.listOf types.port;
        default = [
          80
          443
        ];
        description = ''
          TCP destination ports exposed through the allowlist proxy when
          network.mode is "allowlist". Each configured port accepts HTTP
          requests with an allowed Host header or TLS connections with an
          allowed SNI name; protocols without HTTP Host or TLS SNI are denied.
        '';
      };

      dnsServers = mkOption {
        type = types.listOf types.str;
        default = [
          "1.1.1.1"
          "1.0.0.1"
        ];
        description = ''
          Upstream DNS servers used by unrestricted Internet mode.
        '';
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

    terminal = {
      rows = mkOption {
        type = types.int;
        default = 40;
        description = "Headless terminal row count.";
      };

      columns = mkOption {
        type = types.int;
        default = 120;
        description = "Headless terminal column count.";
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
      isGui = mkOption {
        type = types.bool;
        default = config.verstak.mode == "gui" || config.verstak.gui.enable;
        internal = true;
        description = "Whether GUI mode is effectively enabled.";
      };

      mode = mkOption {
        type = types.enum [
          "headless"
          "gui"
        ];
        default = if config.verstak.internal.isGui then "gui" else "headless";
        internal = true;
        description = "Derived guest mode.";
      };

      vmPrimaryGroup = mkOption {
        type = types.str;
        default =
          if config.verstak.vm.group == null then config.verstak.vm.user else config.verstak.vm.group;
        internal = true;
        description = "Derived guest primary group.";
      };

      vmUserHome = mkOption {
        type = types.str;
        default =
          if config.verstak.vm.home == null then
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

  config.verstak.gui.enable = lib.mkDefault (config.verstak.mode == "gui");
}

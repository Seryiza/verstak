{ config, lib, llmAgents ? null, microvm, pkgs, ... }:

let
  cfg = config.verstak;
  baseTools = import ./tools/base.nix { inherit config lib llmAgents pkgs; };
in {
  nixpkgs.overlays = [ microvm.overlay ]
    ++ lib.optionals (llmAgents != null) [ llmAgents.overlays.default ];

  networking.hostName = "verstak";
  system.stateVersion = cfg.stateVersion;

  microvm = {
    hypervisor = "qemu";

    vcpu = 4;
    mem = cfg.resources.memoryMb;
    socket = "verstak.sock";
    graphics.enable = cfg.gui.enable;

    shares = [
      {
        tag = "project";
        proto = "9p";
        source = cfg.projectRoot;
        mountPoint = cfg.projectMount;
        cache = "metadata";
        securityModel = "mapped";
      }
      {
        tag = "home";
        proto = "virtiofs";
        source = "${cfg.stateDir}/home";
        mountPoint = cfg.internal.vmUserHome;
        cache = "metadata";
      }
    ] ++ lib.optionals cfg.codex.enable [{
      tag = "codex-auth";
      proto = "9p";
      source = "${cfg.stateDir}/codex-auth";
      mountPoint = "/run/verstak-codex-auth";
      readOnly = true;
    }] ++ lib.optionals cfg.claude.enable [{
      tag = "claude-auth";
      proto = "9p";
      source = "${cfg.stateDir}/claude-auth";
      mountPoint = "/run/verstak-claude-auth";
      readOnly = true;
    }] ++ [{
      tag = "ro-store";
      proto = "9p";
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      readOnly = true;
      cache = "always";
    }];

    writableStoreOverlay = "/nix/.rw-store";
    volumes = [{
      image = "${cfg.stateDir}/nix-store-overlay.img";
      mountPoint = config.microvm.writableStoreOverlay;
      size = cfg.resources.storeOverlaySizeMb;
    }];

    interfaces = [{
      type = "user";
      id = "usernet";
      mac = "02:00:00:00:00:01";
    }];

    forwardPorts = lib.optionals cfg.codex.enable [{
      from = "host";
      host.address = cfg.codex.appServer.hostAddress;
      host.port = cfg.codex.appServer.port;
      guest.port = cfg.codex.appServer.port;
    }];

    qemu = {
      serialConsole = false;
      extraArgs = lib.optionals (!cfg.gui.enable) [ "-serial" "chardev:stdio" ];
    };

    kernelParams = lib.optionals (!cfg.gui.enable) [
      "console=ttyS0"
      "8250.nr_uarts=1"
      "quiet"
      "loglevel=0"
      "udev.log_level=3"
      "systemd.show_status=false"
      "rd.systemd.show_status=false"
    ];
  };

  boot.kernelModules =
    lib.optionals cfg.gui.enable [ "drm" "uinput" "virtio_gpu" ];
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = cfg.resources.tmpfsSize;

  networking.firewall.allowedTCPPorts =
    lib.optionals cfg.codex.enable [ cfg.codex.appServer.port ];
  networking.useDHCP = lib.mkDefault true;

  fileSystems.${cfg.projectMount}.options = lib.mkForce [
    "trans=virtio"
    "version=9p2000.L"
    "msize=65536"
    "access=any"
    "x-systemd.after=systemd-modules-load.service"
  ];

  nix = {
    enable = true;
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      sandbox = true;
    };
  };

  users.groups.${cfg.internal.vmPrimaryGroup}.gid = cfg.vm.gid;
  users.users.${cfg.vm.user} = {
    isNormalUser = true;
    uid = cfg.vm.uid;
    group = cfg.internal.vmPrimaryGroup;
    home = cfg.internal.vmUserHome;
    createHome = false;
    extraGroups = [ "wheel" ]
      ++ lib.optionals cfg.gui.enable [ "input" "video" ];
    password = "";
  };

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  environment.sessionVariables = {
    EDITOR = lib.mkDefault "nano";
    GIT_EDITOR = lib.mkDefault "nano";
    HUMAN_EDITOR = "nano";
    VERSTAK_MODE = cfg.internal.mode;
    VERSTAK_PROJECT_MOUNT = cfg.projectMount;
    VISUAL = lib.mkDefault "nano";
    XDG_CACHE_HOME = lib.mkDefault "/tmp/verstak-cache";
  } // lib.optionalAttrs cfg.gui.enable {
    XDG_CURRENT_DESKTOP = "sway";
    XDG_SESSION_TYPE = "wayland";
    WLR_RENDERER_ALLOW_SOFTWARE = "1";
  };

  environment.localBinInPath = true;

  environment.systemPackages = baseTools.packages;

  environment.etc."gitconfig".text = ''
    [safe]
      directory = ${cfg.projectMount}
  '';

  systemd.tmpfiles.rules = [
    "Z ${cfg.projectMount} - ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
    "d ${cfg.internal.vmUserHome} 0755 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
    "d ${cfg.internal.vmUserHome}/.local 0755 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
    "d ${cfg.internal.vmUserHome}/.local/bin 0755 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
  ];
}

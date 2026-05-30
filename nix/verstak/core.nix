{
  config,
  lib,
  llmAgents ? null,
  microvm,
  pkgs,
  ...
}:

let
  cfg = config.verstak;
  baseTools = import ./tools/base.nix {
    inherit
      config
      lib
      llmAgents
      pkgs
      ;
  };
in
{
  nixpkgs.overlays = [
    microvm.overlay
  ]
  ++ lib.optionals (llmAgents != null) [ llmAgents.overlays.default ];

  networking.hostName = "verstak";
  system.stateVersion = cfg.stateVersion;

  microvm = {
    hypervisor = "qemu";

    vcpu = 4;
    mem = cfg.resources.memoryMb;
    socket = "verstak.sock";
    graphics.enable = cfg.internal.isGui;

    shares = [
      {
        tag = "project";
        proto = "virtiofs";
        source = cfg.projectRoot;
        mountPoint = cfg.projectMount;
        cache = "metadata";
      }
      {
        tag = "home";
        proto = "virtiofs";
        source = "${cfg.stateDir}/home";
        mountPoint = cfg.internal.vmUserHome;
        cache = "metadata";
      }
    ]
    ++ lib.optionals cfg.codex.enable [
      {
        tag = "codex-auth";
        proto = "9p";
        source = "${cfg.stateDir}/codex-auth";
        mountPoint = "/run/verstak-codex-auth";
        readOnly = true;
      }
    ]
    ++ lib.optionals cfg.claude.enable [
      {
        tag = "claude-auth";
        proto = "9p";
        source = "${cfg.stateDir}/claude-auth";
        mountPoint = "/run/verstak-claude-auth";
        readOnly = true;
      }
    ]
    ++ [
      {
        tag = "ro-store";
        proto = "9p";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        readOnly = true;
        cache = "always";
      }
    ];

    writableStoreOverlay = "/nix/.rw-store";
    volumes = [
      {
        image = "${cfg.stateDir}/nix-store-overlay.img";
        mountPoint = config.microvm.writableStoreOverlay;
        size = cfg.resources.storeOverlaySizeMb;
      }
    ];

    qemu = {
      serialConsole = false;
      extraArgs = lib.optionals (!cfg.internal.isGui) [
        "-device"
        "virtio-serial-pci"
        "-device"
        "virtconsole,chardev=stdio"
      ];
    };

    kernelParams = lib.optionals (!cfg.internal.isGui) [
      "8250.nr_uarts=1"
      "quiet"
      "loglevel=0"
      "udev.log_level=3"
      "systemd.show_status=false"
      "rd.systemd.show_status=false"
    ];
  };

  boot = {
    kernelModules = lib.optionals cfg.internal.isGui [
      "drm"
      "uinput"
      "virtio_gpu"
    ];

    tmp = {
      useTmpfs = true;
      inherit (cfg.resources) tmpfsSize;
    };
  };

  nix = {
    enable = true;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      sandbox = true;
    };
  };

  users = {
    groups.${cfg.internal.vmPrimaryGroup}.gid = cfg.vm.gid;

    users.${cfg.vm.user} = {
      isNormalUser = true;
      inherit (cfg.vm) uid;
      group = cfg.internal.vmPrimaryGroup;
      home = cfg.internal.vmUserHome;
      createHome = false;
      extraGroups =
        lib.optionals cfg.vm.passwordlessSudo [
          "wheel"
        ]
        ++ lib.optionals cfg.internal.isGui [
          "input"
          "video"
        ];
      password = "";
    };
  };

  warnings =
    lib.optionals
      (cfg.network.mode != "deny" && cfg.network.enforcement == "guest" && cfg.vm.passwordlessSudo)
      [
        ''
          Guest network enforcement is selected while passwordless sudo is enabled.
          Guest root can disable guest nftables/dnsmasq, so this network policy is
          best-effort. Use verstak.network.enforcement = "host" for stronger
          isolation.
        ''
      ];

  security.sudo = {
    enable = cfg.vm.passwordlessSudo;
    wheelNeedsPassword = false;
  };

  environment = {
    sessionVariables = {
      EDITOR = lib.mkDefault "nano";
      GIT_EDITOR = lib.mkDefault "nano";
      HUMAN_EDITOR = "nano";
      VERSTAK_MODE = cfg.internal.mode;
      VERSTAK_NETWORK_MODE = cfg.network.mode;
      VERSTAK_PROJECT_MOUNT = cfg.projectMount;
      VISUAL = lib.mkDefault "nano";
      XDG_CACHE_HOME = lib.mkDefault "/tmp/verstak-cache";
    }
    // lib.optionalAttrs cfg.internal.isGui {
      XDG_CURRENT_DESKTOP = "sway";
      XDG_SESSION_TYPE = "wayland";
      WLR_RENDERER_ALLOW_SOFTWARE = "1";
    };

    localBinInPath = true;
    systemPackages = baseTools.packages;

    etc."gitconfig".text = ''
      [safe]
        directory = ${cfg.projectMount}
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${cfg.internal.vmUserHome} 0755 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
    "d ${cfg.internal.vmUserHome}/.local 0755 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
    "d ${cfg.internal.vmUserHome}/.local/bin 0755 ${cfg.vm.user} ${cfg.internal.vmPrimaryGroup} -"
  ];
}

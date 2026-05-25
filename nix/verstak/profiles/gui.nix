{ config, lib, llmAgents ? null, pkgs, ... }:

let
  cfg = config.verstak;
  baseTools = import ../tools/base.nix { inherit config lib llmAgents pkgs; };
  guiTools = import ../tools/gui.nix { inherit config lib pkgs; };
in {
  config = lib.mkIf cfg.gui.enable {
    hardware.graphics.enable = true;
    services.dbus.enable = true;

    services.udev.extraRules = ''
      KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
    '';

    systemd.services.ydotoold = {
      description = "ydotool virtual input daemon";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart =
          "${pkgs.ydotool}/bin/ydotoold --socket-path=/tmp/.ydotool_socket --socket-perm=0666";
        Restart = "on-failure";
      };
    };

    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
    };

    services.greetd = {
      enable = true;
      settings.default_session = {
        user = cfg.vm.user;
        command = "${pkgs.sway}/bin/sway --config /etc/sway/config";
      };
    };

    xdg.portal = {
      enable = true;
      wlr.enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    };

    fonts.packages = [ pkgs.dejavu_fonts pkgs.nerd-fonts.jetbrains-mono ];

    environment.systemPackages = guiTools.packages;

    environment.etc."sway/config".text = ''
      set $mod Mod1
      set $term ${pkgs.foot}/bin/foot

      output * bg #1d2021 solid_color
      input * xkb_layout us
      workspace_layout tabbed

      exec_always ${pkgs.coreutils}/bin/mkdir -p ${cfg.internal.vmUserHome}/screenshots
      exec ${pkgs.foot}/bin/foot --title verstak-command --hold --working-directory ${cfg.projectMount} ${baseTools.runCommand}/bin/verstak-run-command

      bindsym Print exec ${guiTools.vmScreenshot}/bin/vm-screenshot
      bindsym $mod+Return exec ${pkgs.foot}/bin/foot --working-directory ${cfg.projectMount}
      bindsym $mod+b exec ${pkgs.firefox}/bin/firefox
      bindsym $mod+Shift+e exec ${pkgs.systemd}/bin/systemctl poweroff
    '';
  };
}

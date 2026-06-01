{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.verstak;
  inherit (cfg.internal) hostProgramGuestFwds;
  hostProgramProxyEnabled = hostProgramGuestFwds != [ ];
  networkEnabled = cfg.network.mode != "deny" || hostProgramProxyEnabled;
  internetNetwork = cfg.network.mode == "internet";
  allowlistNetwork = cfg.network.mode == "allowlist";
  guestPolicyEnabled = internetNetwork;
  activeAllowlistGuestFwds = lib.optionals allowlistNetwork allowlistGuestFwds;
  restrictedHostProgramGuestFwds = lib.optionals (!internetNetwork) hostProgramGuestFwds;
  internetHostProgramGuestFwds = lib.optionals internetNetwork hostProgramGuestFwds;
  restrictedGuestFwds = activeAllowlistGuestFwds ++ restrictedHostProgramGuestFwds;
  restrictedUserNetwork = restrictedGuestFwds != [ ];
  internetHostProgramUserNetwork = internetNetwork && internetHostProgramGuestFwds != [ ];
  nftSet = ranges: "{ ${lib.concatStringsSep ", " ranges} }";
  normalizeAllowlistDomain =
    domain:
    let
      trimmed = lib.trim domain;
      withoutPort =
        let
          parts = lib.splitString ":" trimmed;
        in
        if builtins.length parts == 2 && builtins.match "[0-9]+" (builtins.elemAt parts 1) != null then
          builtins.elemAt parts 0
        else
          trimmed;
    in
    lib.toLower (lib.removeSuffix "." (lib.trim withoutPort));
  allowedDomains = lib.unique (
    lib.filter (domain: domain != "") (map normalizeAllowlistDomain cfg.network.allowedDomains)
  );
  allowedTcpPorts = lib.unique cfg.network.allowedTCPPorts;
  allowlistGuestAddress = "10.0.2.100";
  allowlistDnsAddresses = map (domain: "/${domain}/${allowlistGuestAddress}") allowedDomains;
  allowlistProxyPolicy = {
    inherit allowedDomains blockedIPv4Ranges blockedIPv6Ranges;
    allowedTCPPorts = allowedTcpPorts;
  };
  allowlistProxyPolicyFile = pkgs.writeText "verstak-allowlist-proxy-policy.json" (
    builtins.toJSON allowlistProxyPolicy
  );
  allowlistProxy = pkgs.callPackage ../allowlist-proxy { };
  allowlistGuestFwds = map (
    port:
    "guestfwd=tcp:${allowlistGuestAddress}:${toString port}-cmd:${allowlistProxy}/bin/verstak-allowlist-proxy ${allowlistProxyPolicyFile} ${toString port}"
  ) allowedTcpPorts;
  blockedIPv4Ranges = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "192.0.2.0/24"
    "192.88.99.0/24"
    "192.168.0.0/16"
    "198.18.0.0/15"
    "198.51.100.0/24"
    "203.0.113.0/24"
    "224.0.0.0/4"
    "240.0.0.0/4"
  ];
  blockedIPv6Ranges = [
    "::/128"
    "::1/128"
    "::ffff:0:0/96"
    "64:ff9b::/96"
    "100::/64"
    "2001::/23"
    "2001:db8::/32"
    "2002::/16"
    "fc00::/7"
    "fe80::/10"
    "ff00::/8"
  ];
  networkPolicy = allowlistProxyPolicy // {
    inherit (cfg.network) mode dnsServers;
  };
in
{
  assertions = [
    {
      assertion = !allowlistNetwork || allowedDomains != [ ];
      message = ''
        verstak.network.mode = "allowlist" requires at least one
        verstak.network.allowedDomains entry. Select a profile that provides
        domains, add domains in your module, or use --deny-network/--allow-internet.
      '';
    }
    {
      assertion = !allowlistNetwork || allowedTcpPorts != [ ];
      message = ''
        verstak.network.mode = "allowlist" requires at least one
        verstak.network.allowedTCPPorts entry.
      '';
    }
    {
      assertion = !internetNetwork || cfg.network.dnsServers != [ ];
      message = ''
        verstak.network.mode = "${cfg.network.mode}" requires at least one
        verstak.network.dnsServers entry.
      '';
    }
  ];

  warnings = lib.optionals internetNetwork [
    ''
      verstak.network.mode = "internet" uses an in-guest firewall to block
      host/LAN/private ranges. This block is best-effort because guest root can
      alter guest nftables. Allowlist mode is stricter because QEMU restricted
      user networking prevents direct guest egress.
    ''
  ];

  microvm = {
    interfaces = lib.mkForce (
      lib.optionals (networkEnabled && !restrictedUserNetwork) [
        {
          type = "user";
          id = "usernet";
          mac = "02:00:00:00:00:01";
        }
      ]
    );

    qemu.extraArgs =
      lib.optionals restrictedUserNetwork [
        # QEMU guestfwd uses host-side commands for proxied connections. Keep
        # QEMU's seccomp sandbox enabled but explicitly allow spawning those
        # proxy commands.
        "-sandbox"
        "on,spawn=allow"
        "-netdev"
        "user,id=usernet,restrict=on,${lib.concatStringsSep "," restrictedGuestFwds}"
        "-device"
        "virtio-net-device,netdev=usernet,mac=02:00:00:00:00:01"
      ]
      ++ lib.optionals internetHostProgramUserNetwork [
        # Preserve Internet mode's normal user network and add a separate
        # unrestricted host-program guestfwd device for the proxy channel.
        "-sandbox"
        "on,spawn=allow"
        "-netdev"
        "user,id=hostprogramnet,restrict=off,${lib.concatStringsSep "," internetHostProgramGuestFwds}"
        "-device"
        "virtio-net-device,netdev=hostprogramnet,mac=02:00:00:00:00:02"
      ];

    forwardPorts = lib.mkForce (
      lib.optionals (internetNetwork && cfg.codex.enable) [
        {
          from = "host";
          host.address = cfg.codex.appServer.hostAddress;
          host.port = cfg.codex.appServer.port;
          guest.port = cfg.codex.appServer.port;
        }
      ]
    );
  };

  networking = {
    useDHCP = lib.mkDefault networkEnabled;
    enableIPv6 = lib.mkIf networkEnabled false;
    nameservers = lib.mkIf (cfg.network.mode != "deny") (
      if allowlistNetwork then [ "127.0.0.1" ] else cfg.network.dnsServers
    );
    dhcpcd.extraConfig = lib.mkIf networkEnabled "nohook resolv.conf";

    firewall = {
      enable = true;
      allowedTCPPorts = lib.optionals (internetNetwork && cfg.codex.enable) [ cfg.codex.appServer.port ];
    };

    nftables = lib.mkIf guestPolicyEnabled {
      enable = true;
      tables.verstak_egress = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority 0; policy drop;

            oifname "lo" accept
            ct state established,related accept

            # Permit only DHCP lease traffic needed by QEMU user networking.
            udp sport 68 udp dport 67 ip daddr { 255.255.255.255, 10.0.2.2 } accept

            # Block host, private, link-local, multicast, benchmark,
            # documentation, and other non-Internet destination ranges.
            ip daddr ${nftSet blockedIPv4Ranges} drop
            ip6 daddr ${nftSet blockedIPv6Ranges} drop

            ip protocol { tcp, udp, icmp } accept
            ip6 nexthdr { tcp, udp, ipv6-icmp } accept
          }
        '';
      };
    };
  };

  system.build.verstakNetworkPolicy = pkgs.writeText "verstak-network-policy.json" (
    builtins.toJSON networkPolicy
  );

  services.dnsmasq = lib.mkIf allowlistNetwork {
    enable = true;
    settings = {
      "bind-interfaces" = true;
      "cache-size" = 1000;
      "listen-address" = "127.0.0.1";
      "no-resolv" = true;
      address = allowlistDnsAddresses;
    };
  };
}

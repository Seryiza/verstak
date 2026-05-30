{ config, lib, ... }:

let
  cfg = config.verstak;
  networkEnabled = cfg.network.mode != "deny";
  internetNetwork = cfg.network.mode == "internet";
  allowlistNetwork = cfg.network.mode == "allowlist";
  nftSet = ranges: "{ ${lib.concatStringsSep ", " ranges} }";
  allowedDomains = lib.unique cfg.network.allowedDomains;
  allowedTcpPorts = lib.unique cfg.network.allowedTCPPorts;
  allowedTcpPortsSet = nftSet (map toString allowedTcpPorts);
  allowedDomainNftSets = map (
    domain: "/${domain}/4#inet#verstak_egress#allowed_ipv4,6#inet#verstak_egress#allowed_ipv6"
  ) allowedDomains;
  blockedIPv4Ranges = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/8"
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
      assertion = !networkEnabled || cfg.network.dnsServers != [ ];
      message = ''
        verstak.network.mode = "${cfg.network.mode}" requires at least one
        verstak.network.dnsServers entry.
      '';
    }
  ];

  microvm = {
    interfaces = lib.mkForce (
      lib.optionals networkEnabled [
        {
          type = "user";
          id = "usernet";
          mac = "02:00:00:00:00:01";
        }
      ]
    );

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
    nameservers = lib.mkIf networkEnabled (
      if allowlistNetwork then [ "127.0.0.1" ] else cfg.network.dnsServers
    );
    dhcpcd.extraConfig = lib.mkIf networkEnabled "nohook resolv.conf";

    firewall = {
      enable = true;
      allowedTCPPorts = lib.optionals (internetNetwork && cfg.codex.enable) [ cfg.codex.appServer.port ];
    };

    nftables = lib.mkIf networkEnabled {
      enable = true;
      tables.verstak_egress = {
        family = "inet";
        content = ''
          ${lib.optionalString allowlistNetwork ''
            set allowed_ipv4 {
              type ipv4_addr
              flags interval
            }

            set allowed_ipv6 {
              type ipv6_addr
              flags interval
            }
          ''}

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

            ${lib.optionalString allowlistNetwork ''
              # Let the local dnsmasq resolver populate the domain allowlist nft sets.
              ip daddr ${nftSet cfg.network.dnsServers} udp dport 53 accept
              ip daddr ${nftSet cfg.network.dnsServers} tcp dport 53 accept

              # Permit configured TCP ports only to addresses resolved from allowed domains.
              ip daddr @allowed_ipv4 tcp dport ${allowedTcpPortsSet} accept
              ip6 daddr @allowed_ipv6 tcp dport ${allowedTcpPortsSet} accept
            ''}

            ${lib.optionalString internetNetwork ''
              ip protocol { tcp, udp, icmp } accept
              ip6 nexthdr { tcp, udp, ipv6-icmp } accept
            ''}
          }
        '';
      };
    };
  };

  services.dnsmasq = lib.mkIf allowlistNetwork {
    enable = true;
    settings = {
      "bind-interfaces" = true;
      "cache-size" = 1000;
      "listen-address" = "127.0.0.1";
      "no-resolv" = true;
      nftset = allowedDomainNftSets;
      server = cfg.network.dnsServers;
    };
  };

  systemd.services.dnsmasq = lib.mkIf allowlistNetwork {
    after = [ "nftables.service" ];
    wants = [ "nftables.service" ];
    serviceConfig = {
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
    };
  };
}

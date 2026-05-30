#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  verstak [options] [command] [args...]

Options:
  -p, --profile NAME       Add built-in or flake-provided profile
  -C, --directory PATH     Directory to mount at /workspace/project; default: $PWD
  -f, --flake REF          Extra flake ref/directory providing Verstak profiles
  --devshell [REF]         Run command through nix develop; default ref is mounted directory
  --no-devshell            Disable devshell use
  --one-shot, --oneshot    Run command non-interactively and power off when it exits
  --deny-network           Disable all guest networking (default except codex)
  --allow-internet         Allow guest Internet egress while blocking host/LAN ranges
  --network-enforcement MODE
                           Enforce network policy with host netns/nftables or legacy guest firewall (host|guest)
  --guest-network-firewall Also enable legacy in-guest egress firewall as defense-in-depth
  --state-dir PATH         Override VM state dir
  --mem MB                 Override memory
  --store-overlay MB       Override writable Nix store overlay size
  --tmpfs-size SIZE        Override /tmp tmpfs size
  -h, --help               Print help

Verstak options must appear before the command. Use -- before commands that
begin with a dash. For a custom devshell ref, prefer --devshell=REF.
EOF
}

die() {
  echo "verstak: $*" >&2
  exit 1
}

die_usage() {
  echo "verstak: $*" >&2
  echo >&2
  usage >&2
  exit 2
}

has_profile() {
  local needle="$1"
  local profile
  for profile in "${profiles[@]}"; do
    [ "$profile" = "$needle" ] && return 0
  done
  return 1
}

add_profile() {
  local profile="$1"
  [ -n "$profile" ] || die_usage "profile name cannot be empty"
  has_profile "$profile" && return 0
  profiles+=("$profile")
}

sync_seed_file() {
  local source="$1"
  local target="$2"

  if [ -f "$source" ]; then
    @coreutils@/bin/install -m 600 "$source" "$target"
  else
    @coreutils@/bin/rm -f "$target"
  fi
}

looks_like_ref() {
  local ref="$1"
  [[ $ref == "." ]] ||
    [[ $ref == /* ]] ||
    [[ $ref == ./* ]] ||
    [[ $ref == ../* ]] ||
    [[ $ref == *:* ]] ||
    [[ $ref == *flake.nix ]]
}

normalize_flake_ref() {
  local ref="$1"
  local abs

  if [[ $ref == *flake.nix ]]; then
    ref="$(@coreutils@/bin/dirname "$ref")"
  fi

  if [[ $ref == "." || $ref == /* || $ref == ./* || $ref == ../* ]]; then
    abs="$(@coreutils@/bin/realpath "$ref")"
    [ -d "$abs" ] || die "flake path is not a directory: $abs"
    printf 'path:%s\n' "$abs"
  else
    printf '%s\n' "$ref"
  fi
}

normalize_devshell_ref() {
  local ref="$1"
  local abs rel

  if [ -z "$ref" ]; then
    printf '%s\n' "/workspace/project"
    return 0
  fi

  if [[ $ref == *flake.nix ]]; then
    ref="$(@coreutils@/bin/dirname "$ref")"
  fi

  if [[ $ref == "." || $ref == /* || $ref == ./* || $ref == ../* ]]; then
    abs="$(@coreutils@/bin/realpath "$ref")"
    [ -d "$abs" ] || die "devshell path is not a directory: $abs"
    if [ "$abs" = "$project_root" ]; then
      printf '%s\n' "/workspace/project"
    elif [[ $abs == "$project_root/"* ]]; then
      rel="${abs#"$project_root"/}"
      printf '%s/%s\n' "/workspace/project" "$rel"
    else
      die "local devshell paths must be inside the mounted directory: $abs"
    fi
  else
    printf '%s\n' "$ref"
  fi
}

json_array() {
  @jq@/bin/jq -cn '$ARGS.positional' --args -- "$@"
}

profiles=()
extra_flakes=()
command=()
project_root_input="$PWD"
state_dir_input="${VERSTAK_STATE_DIR:-}"
mem_mb="${VERSTAK_MEM_MB:-8192}"
store_overlay_size_mb="${VERSTAK_STORE_OVERLAY_MB:-4096}"
tmpfs_size="${VERSTAK_TMPFS_SIZE:-1G}"
tty_rows="${VERSTAK_TTY_ROWS:-}"
tty_columns="${VERSTAK_TTY_COLUMNS:-}"
codex_app_server_port="${VERSTAK_APP_SERVER_PORT:-4500}"
codex_app_server_host_address="${VERSTAK_APP_SERVER_HOST:-127.0.0.1}"
use_devshell=false
devshell_ref_input=""
one_shot="${VERSTAK_ONE_SHOT:-false}"
network_mode="${VERSTAK_NETWORK_MODE:-deny}"
network_enforcement="${VERSTAK_NETWORK_ENFORCEMENT:-host}"
guest_firewall="${VERSTAK_GUEST_FIREWALL:-false}"
network_mode_explicit=false
if [ -n "${VERSTAK_NETWORK_MODE+x}" ]; then
  network_mode_explicit=true
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
  --)
    shift
    command=("$@")
    break
    ;;
  -p | --profile)
    [ "$#" -ge 2 ] || die_usage "$1 requires a profile name"
    add_profile "$2"
    shift 2
    ;;
  --profile=*)
    add_profile "${1#*=}"
    shift
    ;;
  -C | --directory)
    [ "$#" -ge 2 ] || die_usage "$1 requires a path"
    project_root_input="$2"
    shift 2
    ;;
  --directory=*)
    project_root_input="${1#*=}"
    shift
    ;;
  -f | --flake)
    [ "$#" -ge 2 ] || die_usage "$1 requires a flake ref"
    extra_flakes+=("$(normalize_flake_ref "$2")")
    shift 2
    ;;
  --flake=*)
    extra_flakes+=("$(normalize_flake_ref "${1#*=}")")
    shift
    ;;
  --devshell)
    use_devshell=true
    shift
    if [ "$#" -gt 0 ] && looks_like_ref "$1"; then
      devshell_ref_input="$1"
      shift
    fi
    ;;
  --devshell=*)
    use_devshell=true
    devshell_ref_input="${1#*=}"
    shift
    ;;
  --no-devshell)
    use_devshell=false
    devshell_ref_input=""
    shift
    ;;
  --one-shot | --oneshot)
    one_shot=true
    shift
    ;;
  --deny-network)
    network_mode=deny
    network_mode_explicit=true
    shift
    ;;
  --allow-internet)
    network_mode=internet
    network_mode_explicit=true
    shift
    ;;
  --network-enforcement)
    [ "$#" -ge 2 ] || die_usage "$1 requires host or guest"
    network_enforcement="$2"
    shift 2
    ;;
  --network-enforcement=*)
    network_enforcement="${1#*=}"
    shift
    ;;
  --host-network-enforcement)
    network_enforcement=host
    shift
    ;;
  --guest-network-enforcement)
    network_enforcement=guest
    shift
    ;;
  --guest-network-firewall)
    guest_firewall=true
    shift
    ;;
  --state-dir)
    [ "$#" -ge 2 ] || die_usage "$1 requires a path"
    state_dir_input="$2"
    shift 2
    ;;
  --state-dir=*)
    state_dir_input="${1#*=}"
    shift
    ;;
  --mem)
    [ "$#" -ge 2 ] || die_usage "$1 requires a megabyte value"
    mem_mb="$2"
    shift 2
    ;;
  --mem=*)
    mem_mb="${1#*=}"
    shift
    ;;
  --store-overlay)
    [ "$#" -ge 2 ] || die_usage "$1 requires a mebibyte value"
    store_overlay_size_mb="$2"
    shift 2
    ;;
  --store-overlay=*)
    store_overlay_size_mb="${1#*=}"
    shift
    ;;
  --tmpfs-size)
    [ "$#" -ge 2 ] || die_usage "$1 requires a size"
    tmpfs_size="$2"
    shift 2
    ;;
  --tmpfs-size=*)
    tmpfs_size="${1#*=}"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    die_usage "unknown option: $1"
    ;;
  *)
    command=("$@")
    break
    ;;
  esac
done

if [ "${#command[@]}" -eq 0 ]; then
  command=(bash)
fi

[ -d "$project_root_input" ] ||
  die "project directory does not exist: $project_root_input"
project_root="$(@coreutils@/bin/realpath "$project_root_input")"
project_name="$(@coreutils@/bin/basename "$project_root")"

case "$codex_app_server_port" in
"" | *[!0-9]*)
  die "VERSTAK_APP_SERVER_PORT must be a decimal TCP port"
  ;;
esac
case "$mem_mb" in
"" | *[!0-9]*)
  die "memory must be a decimal number of megabytes"
  ;;
esac
case "$store_overlay_size_mb" in
"" | *[!0-9]*)
  die "store overlay size must be a decimal number of mebibytes"
  ;;
esac
if ! [[ $tmpfs_size =~ ^[0-9]+([KkMmGgTtPpEe]?|%)$ ]]; then
  die "tmpfs size must be a value such as 1024M, 1G, or 50%"
fi
if [ -z "$tty_rows" ] || [ -z "$tty_columns" ]; then
  if [ -t 1 ]; then
    read -r detected_rows detected_columns < <(@coreutils@/bin/stty size 2>/dev/null || printf '40 120\n')
    tty_rows="${tty_rows:-$detected_rows}"
    tty_columns="${tty_columns:-$detected_columns}"
  fi
  tty_rows="${tty_rows:-40}"
  tty_columns="${tty_columns:-120}"
fi
case "$tty_rows" in
"" | *[!0-9]*)
  die "terminal rows must be a decimal number"
  ;;
esac
case "$tty_columns" in
"" | *[!0-9]*)
  die "terminal columns must be a decimal number"
  ;;
esac
if [ "$tty_rows" -le 0 ]; then
  tty_rows=40
fi
if [ "$tty_columns" -le 0 ]; then
  tty_columns=120
fi

case "$one_shot" in
true | false)
  ;;
1)
  one_shot=true
  ;;
0)
  one_shot=false
  ;;
*)
  die "VERSTAK_ONE_SHOT must be true or false"
  ;;
esac
case "$network_mode" in
deny | allowlist | internet)
  ;;
none | off | false | 0)
  network_mode=deny
  ;;
codex | codex-only | openai | openai-codex)
  network_mode=allowlist
  ;;
allow-internet | internet-only | true | 1)
  network_mode=internet
  ;;
*)
  die "VERSTAK_NETWORK_MODE must be 'deny', 'allowlist', or 'internet'"
  ;;
esac
case "$network_enforcement" in
host | guest)
  ;;
*)
  die "VERSTAK_NETWORK_ENFORCEMENT must be 'host' or 'guest'"
  ;;
esac
case "$guest_firewall" in
true | false)
  ;;
1)
  guest_firewall=true
  ;;
0)
  guest_firewall=false
  ;;
*)
  die "VERSTAK_GUEST_FIREWALL must be true or false"
  ;;
esac

if ! has_profile gui && ! has_profile headless; then
  case "${VERSTAK_MODE:-headless}" in
  gui)
    add_profile gui
    ;;
  headless)
    add_profile headless
    ;;
  *)
    die "VERSTAK_MODE must be either 'gui' or 'headless'"
    ;;
  esac
fi

if [ "${command[0]}" = "codex" ]; then
  add_profile codex
  if [ "$network_mode_explicit" = false ]; then
    network_mode=allowlist
  fi
fi
if [ "${command[0]}" = "claude" ]; then
  add_profile claude
fi

mode=headless
has_profile gui && mode=gui

state_dir="${state_dir_input:-$HOME/.local/state/verstak/$project_name}"
devshell_ref="$(normalize_devshell_ref "$devshell_ref_input")"

mkdir -p "$state_dir"
state_dir="$(@coreutils@/bin/realpath "$state_dir")"
mkdir -p "$state_dir/home" "$state_dir/nix-cache"

lock_file="$state_dir/.verstak.lock"
exec 9>"$lock_file"
if ! @utilLinux@/bin/flock -n 9; then
  die "another Verstak VM is already using state dir: $state_dir"
fi

if has_profile codex; then
  mkdir -p "$state_dir/codex-auth"
  sync_seed_file "$HOME/.codex/auth.json" "$state_dir/codex-auth/auth.json"
fi

if has_profile claude; then
  mkdir -p "$state_dir/claude-auth"
  sync_seed_file "$HOME/.claude/.credentials.json" "$state_dir/claude-auth/.credentials.json"
  sync_seed_file "$HOME/.claude/settings.json" "$state_dir/claude-auth/settings.json"
  sync_seed_file "$HOME/.claude.json" "$state_dir/claude-auth/.claude.json"
fi

profiles_json="$(json_array "${profiles[@]}")"
command_json="$(json_array "${command[@]}")"
extra_flakes_json="$(json_array "${extra_flakes[@]}")"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$state_dir/nix-cache}"

runner="$(@nix@/bin/nix build --no-link --print-out-paths \
  -f @runnerConfig@ config.microvm.declaredRunner \
  --arg nixpkgs 'builtins.getFlake "@nixpkgsFlake@"' \
  --arg llmAgents 'builtins.getFlake "@llmAgentsFlake@"' \
  --arg microvm 'builtins.getFlake "@microvmFlake@"' \
  --argstr system '@system@' \
  --argstr projectRoot "$project_root" \
  --argstr projectName "$project_name" \
  --argstr stateDir "$state_dir" \
  --argstr mode "$mode" \
  --argstr profilesJson "$profiles_json" \
  --argstr commandJson "$command_json" \
  --argstr extraFlakesJson "$extra_flakes_json" \
  --arg useDevshell "$use_devshell" \
  --argstr devshellRef "$devshell_ref" \
  --arg oneShot "$one_shot" \
  --arg memMb "$mem_mb" \
  --arg ttyRows "$tty_rows" \
  --arg ttyColumns "$tty_columns" \
  --argstr networkMode "$network_mode" \
  --argstr networkEnforcement "$network_enforcement" \
  --arg guestFirewall "$guest_firewall" \
  --arg storeOverlaySizeMb "$store_overlay_size_mb" \
  --argstr tmpfsSize "$tmpfs_size" \
  --arg codexAppServerPort "$codex_app_server_port" \
  --argstr codexAppServerHostAddress "$codex_app_server_host_address" \
  --arg agentBasePath @agentBasePath@ \
  --arg agentGuiPath @agentGuiPath@ \
  --arg agentHeadlessPath @agentHeadlessPath@ \
  --arg guiSkillPath @guiSkillPath@)"

command_display=""
printf -v command_display '%q ' "${command[@]}"
profile_display=""
printf -v profile_display '%s ' "${profiles[@]}"

cd "$state_dir"

echo "Verstak MicroVM:"
echo "  Profiles: ${profile_display% }"
echo "  Mode:     $mode"
echo "  Project:  $project_root"
echo "  State:    $state_dir"
echo "  Command:  ${command_display% }"
echo "  Session:  $([ "$one_shot" = true ] && printf '%s' one-shot || printf '%s' interactive)"
echo "  Memory:   $mem_mb MB"
echo "  /tmp:     $tmpfs_size tmpfs"
echo "  Terminal: ${tty_columns}x${tty_rows}"
echo "  Nix store overlay: $store_overlay_size_mb MiB"
echo "  Network:  $network_mode ($network_enforcement enforcement)"
if [ "$network_enforcement" = host ] && [ "$network_mode" != deny ]; then
  echo "  Host firewall: netns+nftables (requires sudo for setup/cleanup)"
fi
if [ "$guest_firewall" = true ]; then
  echo "  Guest firewall: enabled as defense-in-depth"
fi
if [ "$use_devshell" = true ]; then
  echo "  Devshell: $devshell_ref"
fi

if has_profile codex && [ "$one_shot" = false ] && [ "${command[0]}" = codex ] && [ "$network_mode" = internet ]; then
  echo "Codex App Server:"
  echo "  VM:   starts codex app-server automatically"
  echo "  Host: codex --dangerously-bypass-approvals-and-sandbox --remote ws://$codex_app_server_host_address:$codex_app_server_port"
fi

host_network_active=false
host_netns=""
host_veth=""
host_nft_nat_table=""
host_nft_filter_table=""

nft_set() {
  local first=true
  printf '{ '
  for item in "$@"; do
    if [ "$first" = true ]; then
      first=false
    else
      printf ', '
    fi
    printf '%s' "$item"
  done
  printf ' }'
}

sudo_run() {
  local sudo_bin
  if [ -x /run/wrappers/bin/sudo ]; then
    sudo_bin=/run/wrappers/bin/sudo
  else
    sudo_bin=sudo
  fi
  "$sudo_bin" "$@"
}

# shellcheck disable=SC2329 # Invoked indirectly through cleanup_all/traps.
cleanup_host_network() {
  if [ "$host_network_active" != true ]; then
    return 0
  fi

  if [ -n "$host_nft_nat_table" ]; then
    sudo_run @nftables@/bin/nft delete table ip "$host_nft_nat_table" 2>/dev/null || true
  fi
  if [ -n "$host_nft_filter_table" ]; then
    sudo_run @nftables@/bin/nft delete table inet "$host_nft_filter_table" 2>/dev/null || true
  fi
  if [ -n "$host_netns" ]; then
    sudo_run @iproute2@/bin/ip netns delete "$host_netns" 2>/dev/null || true
  fi
  if [ -n "$host_veth" ]; then
    sudo_run @iproute2@/bin/ip link delete "$host_veth" 2>/dev/null || true
  fi

  host_network_active=false
}

populate_host_allowlist() {
  local domain query server record ip
  local -a queries
  local -a allowed_domains

  allowed_domains=()
  if has_profile codex; then
    allowed_domains+=(openai.com chatgpt.com oaistatic.com oaiusercontent.com)
  fi

  if [ "${#allowed_domains[@]}" -eq 0 ]; then
    die "host-enforced allowlist mode has no known allowed domains; select a profile that contributes domains or use --allow-internet"
  fi

  server="1.1.1.1"
  echo "  Allowlist domains: ${allowed_domains[*]}"
  echo "  Note: host allowlist currently pre-resolves common domain names; CDN-shared IPs and unlisted subdomains remain a limitation."

  for domain in "${allowed_domains[@]}"; do
    queries=("$domain" "api.$domain" "auth.$domain" "chat.$domain" "cdn.$domain" "files.$domain" "static.$domain")
    for query in "${queries[@]}"; do
      while IFS= read -r record; do
        if [[ $record =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
          ip="$record"
          sudo_run @iproute2@/bin/ip netns exec "$host_netns" \
            @nftables@/bin/nft add element inet verstak_egress allowed_ipv4 "{ $ip }" 2>/dev/null || true
        fi
      done < <(sudo_run @iproute2@/bin/ip netns exec "$host_netns" \
        @dnsutils@/bin/dig +time=2 +tries=1 +short A "$query" "@$server" 2>/dev/null || true)
    done
  done
}

setup_host_network() {
  local hash octet subnet host_ip ns_ip ns_veth dns_set tcp_ports_set
  local -a blocked_ipv4_ranges blocked_ipv6_ranges dns_servers allowed_tcp_ports

  if [ "$network_mode" = deny ] || [ "$network_enforcement" != host ]; then
    return 0
  fi

  hash="$(@coreutils@/bin/printf '%s' "$state_dir" | @coreutils@/bin/sha256sum | @coreutils@/bin/cut -c1-12)"
  octet=$((16#${hash:0:2}))
  host_netns="verstak-${hash:0:10}"
  host_veth="vst${hash:0:6}h"
  ns_veth="vst${hash:0:6}n"
  host_nft_nat_table="verstak_${hash:0:10}_nat"
  host_nft_filter_table="verstak_${hash:0:10}_filter"
  subnet="10.247.$octet.0/30"
  host_ip="10.247.$octet.1"
  ns_ip="10.247.$octet.2"

  dns_servers=(1.1.1.1 1.0.0.1)
  allowed_tcp_ports=(80 443)
  blocked_ipv4_ranges=(
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8
    169.254.0.0/16 172.16.0.0/12 192.0.0.0/8 198.18.0.0/15
    198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
  )
  blocked_ipv6_ranges=(
    ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 100::/64 2001::/23
    2001:db8::/32 2002::/16 fc00::/7 fe80::/10 ff00::/8
  )
  dns_set="$(nft_set "${dns_servers[@]}")"
  tcp_ports_set="$(nft_set "${allowed_tcp_ports[@]}")"

  echo "Setting up host-enforced network namespace: $host_netns"

  sudo_run @nftables@/bin/nft delete table ip "$host_nft_nat_table" 2>/dev/null || true
  sudo_run @nftables@/bin/nft delete table inet "$host_nft_filter_table" 2>/dev/null || true
  sudo_run @iproute2@/bin/ip netns delete "$host_netns" 2>/dev/null || true
  sudo_run @iproute2@/bin/ip link delete "$host_veth" 2>/dev/null || true

  sudo_run @iproute2@/bin/ip netns add "$host_netns"
  host_network_active=true
  sudo_run @iproute2@/bin/ip link add "$host_veth" type veth peer name "$ns_veth"
  sudo_run @iproute2@/bin/ip link set "$ns_veth" netns "$host_netns"
  sudo_run @iproute2@/bin/ip addr add "$host_ip/30" dev "$host_veth"
  sudo_run @iproute2@/bin/ip link set "$host_veth" up
  sudo_run @iproute2@/bin/ip netns exec "$host_netns" @iproute2@/bin/ip addr add "$ns_ip/30" dev "$ns_veth"
  sudo_run @iproute2@/bin/ip netns exec "$host_netns" @iproute2@/bin/ip link set lo up
  sudo_run @iproute2@/bin/ip netns exec "$host_netns" @iproute2@/bin/ip link set "$ns_veth" up
  sudo_run @iproute2@/bin/ip netns exec "$host_netns" @iproute2@/bin/ip route add default via "$host_ip"
  echo 1 | sudo_run @coreutils@/bin/tee /proc/sys/net/ipv4/ip_forward >/dev/null

  sudo_run @nftables@/bin/nft -f - <<EOF_NFT_HOST
 table ip $host_nft_nat_table {
   chain postrouting {
     type nat hook postrouting priority srcnat; policy accept;
     ip saddr $subnet masquerade
   }
 }
 table inet $host_nft_filter_table {
   chain forward {
     type filter hook forward priority -50; policy accept;
     iifname "$host_veth" accept
     oifname "$host_veth" ct state established,related accept
   }
 }
EOF_NFT_HOST

  sudo_run @iproute2@/bin/ip netns exec "$host_netns" @nftables@/bin/nft -f - <<EOF_NFT_NS
 table inet verstak_egress {
   set allowed_ipv4 {
     type ipv4_addr
     flags interval
   }

   chain output {
     type filter hook output priority 0; policy drop;

     oifname "lo" accept
     ct state established,related accept

     ip daddr $dns_set udp dport 53 accept
     ip daddr $dns_set tcp dport 53 accept

     ip daddr $(nft_set "${blocked_ipv4_ranges[@]}") drop
     ip6 daddr $(nft_set "${blocked_ipv6_ranges[@]}") drop

     $(if [ "$network_mode" = internet ]; then
    printf '%s\n' 'ip protocol { tcp, udp, icmp } accept'
    printf '%s\n' 'ip6 nexthdr { tcp, udp, ipv6-icmp } accept'
  else
    printf '%s\n' "ip daddr @allowed_ipv4 tcp dport $tcp_ports_set accept"
  fi)
   }
 }
EOF_NFT_NS

  if [ "$network_mode" = allowlist ]; then
    populate_host_allowlist
  fi
}

run_microvm() {
  local uid gid group_list
  local -a env_args

  if [ "$network_mode" != deny ] && [ "$network_enforcement" = host ]; then
    uid="$(@coreutils@/bin/id -u)"
    gid="$(@coreutils@/bin/id -g)"
    group_list="$(@coreutils@/bin/id -G | @coreutils@/bin/tr ' ' ',' | @coreutils@/bin/tr -d '\n')"
    env_args=(
      "HOME=$HOME"
      "USER=${USER:-}"
      "LOGNAME=${LOGNAME:-}"
      "XDG_CACHE_HOME=$XDG_CACHE_HOME"
    )
    [ -n "${DISPLAY:-}" ] && env_args+=("DISPLAY=$DISPLAY")
    [ -n "${WAYLAND_DISPLAY:-}" ] && env_args+=("WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
    [ -n "${XAUTHORITY:-}" ] && env_args+=("XAUTHORITY=$XAUTHORITY")
    [ -n "${XDG_RUNTIME_DIR:-}" ] && env_args+=("XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")

    sudo_run @iproute2@/bin/ip netns exec "$host_netns" \
      @utilLinux@/bin/setpriv --reuid "$uid" --regid "$gid" --groups "$group_list" -- \
      @coreutils@/bin/env "${env_args[@]}" "$runner/bin/microvm-run"
  else
    "$runner/bin/microvm-run"
  fi
}

virtiofsd_pids=()
virtiofsd_sockets=()
# shellcheck disable=SC2329 # Invoked indirectly through traps.
cleanup_virtiofsd() {
  local pid
  local socket_path
  for pid in "${virtiofsd_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  for socket_path in "${virtiofsd_sockets[@]}"; do
    @coreutils@/bin/rm -f "$socket_path"
  done
}

# shellcheck disable=SC2329 # Invoked indirectly through traps.
cleanup_all() {
  cleanup_virtiofsd
  cleanup_host_network
}

trap cleanup_all EXIT
trap 'trap - INT; cleanup_all; kill -INT "$$"' INT
trap 'trap - TERM; cleanup_all; kill -TERM "$$"' TERM

setup_host_network

if [ -d "$runner/share/microvm/virtiofs" ]; then
  # nix run does not use microvm.nix's host systemd units, so the launcher
  # starts the virtiofs daemon that backs the VM home share.
  for socket_file in "$runner"/share/microvm/virtiofs/*/socket; do
    [ -e "$socket_file" ] || continue
    tag_dir="${socket_file%/socket}"
    socket_path="$(@coreutils@/bin/cat "$socket_file")"
    source_path="$(@coreutils@/bin/cat "$tag_dir/source")"
    nofile_limit="$(ulimit -Hn)"
    virtiofsd_sockets+=("$socket_path")
    @coreutils@/bin/rm -f "$socket_path"
    @virtiofsd@/bin/virtiofsd \
      --socket-path="$socket_path" \
      --shared-dir="$source_path" \
      --thread-pool-size 1 \
      --sandbox=none \
      --seccomp=none \
      --rlimit-nofile="$nofile_limit" \
      --cache=metadata \
      --allow-mmap \
      --inode-file-handles=never \
      "--translate-uid=squash-guest:0:$(@coreutils@/bin/id -u):65536" \
      "--translate-gid=squash-guest:0:$(@coreutils@/bin/id -g):65536" \
      >>"$state_dir/virtiofsd.log" 2>&1 &
    virtiofsd_pids+=("$!")

    for _ in {1..100}; do
      if [ -S "$socket_path" ]; then
        break
      fi
      if ! kill -0 "${virtiofsd_pids[-1]}" 2>/dev/null; then
        die "virtiofsd exited before creating $socket_path"
      fi
      @coreutils@/bin/sleep 0.05
    done
    [ -S "$socket_path" ] || die "timed out waiting for virtiofsd socket $socket_path"
  done
fi

run_status=0
run_microvm || run_status=$?
exit "$run_status"

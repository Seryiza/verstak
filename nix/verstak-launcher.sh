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
  --allow-internet         Allow guest Internet egress; host/LAN blocking is best-effort
  --allow-host-programs NAMES
                            Comma-separated host PATH program names to proxy into the VM
  --host-programs-policy PATH
                            JSON host-program policy with allow/forbid rules
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

trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

add_host_programs_csv() {
  local csv="$1"
  local raw
  local program
  local -a host_program_items
  [ -n "$csv" ] || die_usage "host program names cannot be empty"
  IFS=',' read -r -a host_program_items <<<"$csv"
  for raw in "${host_program_items[@]}"; do
    program="$(trim_space "$raw")"
    [ -n "$program" ] || die_usage "host program names cannot be empty"
    [[ $program != "." && $program != ".." ]] || die_usage "host program name must be a simple PATH name: $program"
    [[ $program =~ ^[A-Za-z0-9._+-]+$ ]] || die_usage "host program name must be a simple PATH name: $program"
    host_programs+=("$program")
  done
}

load_host_programs_policy() {
  local policy_path="$1"
  [ -f "$policy_path" ] || die "host-program policy file does not exist: $policy_path"
  @jq@/bin/jq -e '
    def rule_string: type == "string" and test("[^[:space:]]");
    type == "object"
    and ((keys - ["allow", "forbid"]) | length == 0)
    and ((.allow // []) | type == "array")
    and ((.forbid // []) | type == "array")
    and all(.allow[]?; rule_string)
    and all(.forbid[]?; rule_string)
  ' "$policy_path" >/dev/null || die "host-program policy must be a JSON object with only non-empty string allow/forbid arrays: $policy_path"
  @jq@/bin/jq -c '{ allow: (.allow // []), forbid: (.forbid // []) }' "$policy_path"
}

profiles=()
extra_flakes=()
command=()
host_programs=()
host_programs_policy_input=""
host_programs_policy_json='{"allow":[],"forbid":[]}'
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
network_mode_explicit=false
network_mode_alias=""
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
  --allow-host-programs)
    [ "$#" -ge 2 ] || die_usage "$1 requires a comma-separated program list"
    add_host_programs_csv "$2"
    shift 2
    ;;
  --allow-host-programs=*)
    add_host_programs_csv "${1#*=}"
    shift
    ;;
  --host-programs-policy)
    [ "$#" -ge 2 ] || die_usage "$1 requires a JSON policy path"
    host_programs_policy_input="$2"
    shift 2
    ;;
  --host-programs-policy=*)
    host_programs_policy_input="${1#*=}"
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
  network_mode_alias="$network_mode"
  network_mode=allowlist
  ;;
allow-internet | internet-only | true | 1)
  network_mode=internet
  ;;
*)
  die "VERSTAK_NETWORK_MODE must be 'deny', 'allowlist', or 'internet'"
  ;;
esac
if [ -n "$network_mode_alias" ] && [ "${command[0]}" != "codex" ]; then
  die "VERSTAK_NETWORK_MODE=$network_mode_alias is only valid with the codex command; use VERSTAK_NETWORK_MODE=allowlist with a profile/module that provides domains, or run 'verstak codex'"
fi
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

if [ -n "$host_programs_policy_input" ]; then
  host_programs_policy_json="$(load_host_programs_policy "$host_programs_policy_input")"
fi
host_programs_json="$(json_array "${host_programs[@]}")"
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
  --argstr hostProgramsJson "$host_programs_json" \
  --argstr hostProgramsPolicyJson "$host_programs_policy_json" \
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
echo "  Network:  $network_mode"
if [ "${#host_programs[@]}" -gt 0 ] || [ -n "$host_programs_policy_input" ]; then
  host_programs_display=""
  printf -v host_programs_display '%s ' "${host_programs[@]}"
  echo "  Host programs: ${host_programs_display% }${host_programs_policy_input:+ policy=$host_programs_policy_input}"
fi
if [ "$use_devshell" = true ]; then
  echo "  Devshell: $devshell_ref"
fi

if has_profile codex && [ "$one_shot" = false ] && [ "${command[0]}" = codex ] && [ "$network_mode" = internet ]; then
  echo "Codex App Server:"
  echo "  VM:   starts codex app-server automatically"
  echo "  Host: codex --dangerously-bypass-approvals-and-sandbox --remote ws://$codex_app_server_host_address:$codex_app_server_port"
fi

run_microvm() {
  "$runner/bin/microvm-run"
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
}

trap cleanup_all EXIT
trap 'trap - INT; cleanup_all; kill -INT "$$"' INT
trap 'trap - TERM; cleanup_all; kill -TERM "$$"' TERM

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

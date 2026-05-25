{ config, lib, pkgs }:

let
  cfg = config.verstak;

  vmWindows = pkgs.writeShellScriptBin "vm-windows" ''
    set -euo pipefail
    ${pkgs.sway}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -r '
      [
        .. | objects
        | select(.type? == "con" or .type? == "floating_con")
        | select(.pid? != null or .app_id? != null or .window_properties? != null)
        | select(((.rect.width? // 0) > 0) and ((.rect.height? // 0) > 0))
        | {
            id,
            app_id: (.app_id // ""),
            class: (.window_properties.class // ""),
            title: (.name // .window_properties.title // ""),
            focused: (.focused // false),
            rect
          }
      ]
      | (["id", "app_id", "class", "focused", "geometry", "title"] | @tsv),
        (.[] | [
          (.id | tostring),
          .app_id,
          .class,
          (.focused | tostring),
          "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)",
          .title
        ] | @tsv)
    '
  '';

  vmScreenshot = pkgs.writeShellScriptBin "vm-screenshot" ''
    set -euo pipefail

    query=""
    if [ "$#" -eq 0 ]; then
      out="${cfg.internal.vmUserHome}/screenshots/screenshot-$(date +%Y%m%d-%H%M%S).png"
    elif [ "$#" -eq 1 ] && { [[ "$1" == */* ]] || [[ "$1" == *.png ]]; }; then
      out="$1"
    elif [ "$#" -eq 1 ]; then
      query="$1"
      safe_query="$(printf '%s' "$query" | ${pkgs.coreutils}/bin/tr -cs 'A-Za-z0-9_.-' '-')"
      out="${cfg.internal.vmUserHome}/screenshots/screenshot-$safe_query-$(date +%Y%m%d-%H%M%S).png"
    else
      query="$1"
      out="$2"
    fi

    mkdir -p "$(dirname "$out")"

    if [ -z "$query" ]; then
      exec ${pkgs.grim}/bin/grim "$out"
    fi

    geometry="$(${pkgs.sway}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -er --arg q "$query" '
      def text:
        [
          .app_id,
          .name,
          .window_properties.class,
          .window_properties.title
        ]
        | map(. // "")
        | join(" ")
        | ascii_downcase;
      def real_window:
        (.pid? != null or .app_id? != null or .window_properties? != null)
        and ((.rect.width? // 0) > 0)
        and ((.rect.height? // 0) > 0);
      [
        .. | objects
        | select(.type? == "con" or .type? == "floating_con")
        | select(real_window)
        | select(text | contains($q | ascii_downcase))
      ]
      | sort_by(if .focused then 0 else 1 end, .rect.x, .rect.y)
      | .[0].rect
      | "\(.x),\(.y) \(.width)x\(.height)"
    ')" || {
      echo "No visible Sway window matched '$query'." >&2
      echo "Visible windows:" >&2
      ${vmWindows}/bin/vm-windows >&2 || true
      exit 1
    }

    if ! [[ "$geometry" =~ ^[0-9]+,[0-9]+\ [1-9][0-9]*x[1-9][0-9]*$ ]]; then
      echo "Invalid geometry for '$query': $geometry" >&2
      exit 1
    fi

    exec ${pkgs.grim}/bin/grim -g "$geometry" "$out"
  '';

  vmFocus = pkgs.writeShellScriptBin "vm-focus" ''
    set -euo pipefail
    if [ "$#" -lt 1 ]; then
      echo "Usage: vm-focus <app-id-or-title-fragment>" >&2
      exit 2
    fi

    query="$*"
    id="$(${pkgs.sway}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -er --arg q "$query" '
      def text:
        [
          .app_id,
          .name,
          .window_properties.class,
          .window_properties.title
        ]
        | map(. // "")
        | join(" ")
        | ascii_downcase;
      def real_window:
        (.pid? != null or .app_id? != null or .window_properties? != null)
        and ((.rect.width? // 0) > 0)
        and ((.rect.height? // 0) > 0);
      [
        .. | objects
        | select(.type? == "con" or .type? == "floating_con")
        | select(real_window)
        | select(text | contains($q | ascii_downcase))
      ]
      | sort_by(if .focused then 0 else 1 end, .rect.x, .rect.y)
      | .[0].id
    ')" || {
      echo "No visible Sway window matched '$query'." >&2
      echo "Visible windows:" >&2
      ${vmWindows}/bin/vm-windows >&2 || true
      exit 1
    }

    exec ${pkgs.sway}/bin/swaymsg "[con_id=$id]" focus
  '';

  vmType = pkgs.writeShellScriptBin "vm-type" ''
    set -euo pipefail
    exec ${pkgs.wtype}/bin/wtype "$*"
  '';

  vmKey = pkgs.writeShellScriptBin "vm-key" ''
    set -euo pipefail

    if [ "$#" -lt 1 ]; then
      echo "Usage: vm-key <key-or-chord>..." >&2
      echo "Examples: vm-key Return, vm-key Ctrl+x, vm-key C-x, vm-key Alt+Return" >&2
      exit 2
    fi

    normalize_modifier() {
      case "''${1,,}" in
        c|ctrl|control)
          printf '%s\n' ctrl
          ;;
        a|alt|m|meta)
          printf '%s\n' alt
          ;;
        s|shift)
          printf '%s\n' shift
          ;;
        super|logo|win|windows|mod4)
          printf '%s\n' logo
          ;;
        *)
          echo "Unknown modifier '$1'" >&2
          exit 2
          ;;
      esac
    }

    send_key() {
      local spec="$1"
      local -a parts modifiers mods args
      local key

      if [[ "$spec" == *+* ]]; then
        IFS=+ read -r -a parts <<< "$spec"
      elif [[ "$spec" =~ ^(C|c|M|m|S|s|A|a|Ctrl|ctrl|Control|control|Alt|alt|Meta|meta|Shift|shift)-.+$ ]]; then
        IFS=- read -r -a parts <<< "$spec"
      else
        ${pkgs.wtype}/bin/wtype -k "$spec"
        return
      fi

      if [ "''${#parts[@]}" -lt 2 ]; then
        echo "Invalid key chord '$spec'" >&2
        exit 2
      fi

      key="''${parts[$((''${#parts[@]} - 1))]}"
      modifiers=("''${parts[@]:0:$((''${#parts[@]} - 1))}")
      mods=()
      for modifier in "''${modifiers[@]}"; do
        mods+=("$(normalize_modifier "$modifier")")
      done

      args=()
      for modifier in "''${mods[@]}"; do
        args+=(-M "$modifier")
      done
      args+=(-k "$key")
      for ((i = ''${#mods[@]} - 1; i >= 0; i--)); do
        args+=(-m "''${mods[$i]}")
      done

      ${pkgs.wtype}/bin/wtype "''${args[@]}"
    }

    for key in "$@"; do
      send_key "$key"
    done
  '';

  vmClick = pkgs.writeShellScriptBin "vm-click" ''
    set -euo pipefail
    button="''${1:-0xC0}"
    export YDOTOOL_SOCKET=/tmp/.ydotool_socket
    exec ${pkgs.ydotool}/bin/ydotool click "$button"
  '';

  vmMoveMouse = pkgs.writeShellScriptBin "vm-move-mouse" ''
    set -euo pipefail
    if [ "$#" -ne 2 ]; then
      echo "Usage: vm-move-mouse <x> <y>" >&2
      exit 2
    fi

    export YDOTOOL_SOCKET=/tmp/.ydotool_socket
    exec ${pkgs.ydotool}/bin/ydotool mousemove --absolute "$1" "$2"
  '';
in {
  inherit vmClick vmFocus vmKey vmMoveMouse vmScreenshot vmType vmWindows;

  packages = [
    pkgs.firefox
    pkgs.foot
    pkgs.grim
    pkgs.slurp
    pkgs.sway
    vmClick
    vmFocus
    vmKey
    vmMoveMouse
    vmScreenshot
    vmType
    vmWindows
    pkgs.wayland-utils
    pkgs.wl-clipboard
    pkgs.wtype
    pkgs.xdg-utils
    pkgs.ydotool
  ];
}

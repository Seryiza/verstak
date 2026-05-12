{
  description = "QEMU-only Codex MicroVM for project workspaces";

  nixConfig = {
    extra-substituters =
      [ "https://microvm.cachix.org" "https://cache.numtide.com" ];
    extra-trusted-public-keys = [
      "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    llm-agents.url = "github:numtide/llm-agents.nix";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, llm-agents, microvm, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkPkgs = system:
        import nixpkgs {
          inherit system;
          overlays = [ microvm.overlay llm-agents.overlays.default ];
        };
    in {
      devShells = forAllSystems (system:
        let pkgs = mkPkgs system;
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              bubblewrap
              codex
              deadnix
              fd
              git
              nil
              nix-direnv
              nixfmt
              nixpkgs-fmt
              ripgrep
              statix
            ];

            shellHook = ''
              echo "verstak dev shell"
              echo "check:    nix flake check"
              echo "gui:      nix run . -- /path/to/project"
              echo "headless: nix run .#headless -- /path/to/project"
            '';
          };
        });

      apps = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          runnerConfig = ./nix/codex-microvm.nix;

          mkApp = defaultMode: {
            type = "app";
            meta.description = "Run the Verstak ${defaultMode} QEMU MicroVM";
            program = toString
              (pkgs.writeShellScript "run-verstak-${defaultMode}" ''
                set -euo pipefail

                if [ "$#" -gt 1 ]; then
                  echo "Usage: nix run .#${defaultMode} -- [project-root]" >&2
                  exit 2
                fi

                project_root_input="''${1:-$PWD}"
                if [ ! -d "$project_root_input" ]; then
                  echo "Project root does not exist or is not a directory: $project_root_input" >&2
                  exit 1
                fi

                project_root="$(${pkgs.coreutils}/bin/realpath "$project_root_input")"
                project_name="$(${pkgs.coreutils}/bin/basename "$project_root")"
                state_dir="''${VERSTAK_STATE_DIR:-$HOME/.local/state/verstak/$project_name}"
                codex_app_server_port="''${VERSTAK_APP_SERVER_PORT:-4500}"
                codex_app_server_host_address="''${VERSTAK_APP_SERVER_HOST:-127.0.0.1}"
                mem_mb="''${VERSTAK_MEM_MB:-8192}"
                store_overlay_size_mb="''${VERSTAK_STORE_OVERLAY_MB:-4096}"
                tmpfs_size="''${VERSTAK_TMPFS_SIZE:-1G}"
                mode="''${VERSTAK_MODE:-${defaultMode}}"

                case "$codex_app_server_port" in
                  ""|*[!0-9]*)
                    echo "VERSTAK_APP_SERVER_PORT must be a decimal TCP port." >&2
                    exit 1
                    ;;
                esac
                case "$mem_mb" in
                  ""|*[!0-9]*)
                    echo "VERSTAK_MEM_MB must be a decimal number of megabytes." >&2
                    exit 1
                    ;;
                esac
                case "$store_overlay_size_mb" in
                  ""|*[!0-9]*)
                    echo "VERSTAK_STORE_OVERLAY_MB must be a decimal number of mebibytes." >&2
                    exit 1
                    ;;
                esac
                if ! [[ "$tmpfs_size" =~ ^[0-9]+([KkMmGgTtPpEe]?|%)$ ]]; then
                  echo "VERSTAK_TMPFS_SIZE must be a tmpfs size such as 1024M, 1G, or 50%." >&2
                  exit 1
                fi
                case "$mode" in
                  gui)
                    enable_gui=true
                    ;;
                  headless)
                    enable_gui=false
                    ;;
                  *)
                    echo "VERSTAK_MODE must be either 'gui' or 'headless'." >&2
                    exit 1
                    ;;
                esac

                mkdir -p "$state_dir/home" "$state_dir/codex-auth" "$state_dir/nix-cache"

                host_codex_auth="$HOME/.codex/auth.json"
                if [ -f "$host_codex_auth" ]; then
                  ${pkgs.coreutils}/bin/install -m 600 "$host_codex_auth" "$state_dir/codex-auth/auth.json"
                fi

                export XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$state_dir/nix-cache}"

                runner="$(${pkgs.nix}/bin/nix build --no-link --print-out-paths \
                  -f ${runnerConfig} config.microvm.declaredRunner \
                  --arg nixpkgs 'builtins.getFlake "${nixpkgs}"' \
                  --arg llmAgents 'builtins.getFlake "${llm-agents}"' \
                  --arg microvm 'builtins.getFlake "${microvm}"' \
                  --argstr system '${system}' \
                  --argstr projectRoot "$project_root" \
                  --argstr projectName "$project_name" \
                  --argstr stateDir "$state_dir" \
                  --arg enableGui "$enable_gui" \
                  --arg memMb "$mem_mb" \
                  --arg storeOverlaySizeMb "$store_overlay_size_mb" \
                  --argstr tmpfsSize "$tmpfs_size" \
                  --arg codexAppServerPort "$codex_app_server_port" \
                  --argstr codexAppServerHostAddress "$codex_app_server_host_address" \
                  --arg agentBasePath '${./agents/vm-base.md}' \
                  --arg agentGuiPath '${./agents/vm-gui.md}' \
                  --arg agentHeadlessPath '${./agents/vm-headless.md}' \
                  --arg guiSkillPath '${./skills/vm-gui/SKILL.md}')"

                cd "$state_dir"

                echo "Verstak MicroVM:"
                echo "  Mode:    $mode"
                echo "  Project: $project_root"
                echo "  State:   $state_dir"
                echo "  Memory:  $mem_mb MB"
                echo "  /tmp:    $tmpfs_size tmpfs"
                echo "  Nix store overlay: $store_overlay_size_mb MiB"
                echo "Codex App Server:"
                echo "  VM:   starts codex-app-server automatically"
                echo "  Host: codex --dangerously-bypass-approvals-and-sandbox --remote ws://$codex_app_server_host_address:$codex_app_server_port"

                exec "$runner/bin/microvm-run"
              '');
          };

          gui = mkApp "gui";
          headless = mkApp "headless";
        in {
          default = gui;
          inherit gui headless;
        });

      nixosConfigurations.verstak = import ./nix/codex-microvm.nix {
        inherit nixpkgs microvm;
        llmAgents = llm-agents;
        system = "x86_64-linux";
        projectRoot = toString self;
        projectName = "verstak";
        stateDir = "/var/lib/verstak";
        enableGui = true;
        agentBasePath = ./agents/vm-base.md;
        agentGuiPath = ./agents/vm-gui.md;
        agentHeadlessPath = ./agents/vm-headless.md;
        guiSkillPath = ./skills/vm-gui/SKILL.md;
      };
    };
}

{
  description = "QEMU-only composable MicroVM command runner";

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
      mkVerstakSystem = import ./nix/verstak-microvm.nix;
      docs = {
        agentBasePath = ./agents/vm-base.md;
        agentGuiPath = ./agents/vm-gui.md;
        agentHeadlessPath = ./agents/vm-headless.md;
        guiSkillPath = ./skills/vm-gui/SKILL.md;
      };

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
            packages = [
              pkgs.bubblewrap
              pkgs.codex
              pkgs.deadnix
              pkgs.fd
              pkgs.git
              pkgs.nil
              pkgs.nix-direnv
              pkgs.nixfmt
              pkgs.nixpkgs-fmt
              pkgs.ripgrep
              pkgs.statix
            ];

            shellHook = ''
              echo "verstak dev shell"
              echo "check:    nix flake check"
              echo "run:      nix run . -- codex"
              echo "gui:      nix run . -- -p gui codex"
            '';
          };
        });

      formatter = forAllSystems (system: (mkPkgs system).nixfmt);

      apps = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          launcher = pkgs.replaceVarsWith {
            name = "verstak";
            src = ./nix/verstak-launcher.sh;
            isExecutable = true;
            replacements = {
              nix = pkgs.nix;
              coreutils = pkgs.coreutils;
              jq = pkgs.jq;
              utilLinux = pkgs.util-linux;
              virtiofsd = pkgs.virtiofsd;
              runnerConfig = ./nix/verstak-microvm.nix;
              nixpkgsFlake = nixpkgs;
              llmAgentsFlake = llm-agents;
              microvmFlake = microvm;
              inherit system;
            } // docs;
          };
        in {
          default = {
            type = "app";
            meta.description = "Run a command inside the Verstak QEMU MicroVM";
            program = toString launcher;
          };
        });

      nixosConfigurations.verstak = mkVerstakSystem ({
        inherit nixpkgs microvm;
        llmAgents = llm-agents;
        system = "x86_64-linux";
        projectRoot = toString self;
        projectName = "verstak";
        stateDir = "/var/lib/verstak";
        profilesJson = builtins.toJSON [ "headless" ];
        commandJson = builtins.toJSON [ "bash" ];
      } // docs);
    };
}

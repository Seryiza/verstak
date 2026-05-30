{
  description = "QEMU-only composable MicroVM command runner";

  nixConfig = {
    extra-substituters = [
      "https://microvm.cachix.org"
      "https://cache.numtide.com"
    ];
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
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      llm-agents,
      microvm,
      git-hooks,
      treefmt-nix,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkVerstakSystem = import ./nix/verstak-microvm.nix;
      docs = {
        agentBasePath = ./agents/vm-base.md;
        agentGuiPath = ./agents/vm-gui.md;
        agentHeadlessPath = ./agents/vm-headless.md;
        guiSkillPath = ./skills/vm-gui/SKILL.md;
      };

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            microvm.overlay
            llm-agents.overlays.default
          ];
        };

      devTools = pkgs: import ./nix/dev-tools.nix { inherit pkgs; };

      mkLauncher =
        system:
        let
          pkgs = mkPkgs system;
        in
        pkgs.replaceVarsWith {
          name = "verstak";
          src = ./nix/verstak-launcher.sh;
          isExecutable = true;
          replacements = {
            inherit (pkgs)
              coreutils
              dnsutils
              iproute2
              jq
              nftables
              nix
              virtiofsd
              ;
            utilLinux = pkgs.util-linux;
            runnerConfig = ./nix/verstak-microvm.nix;
            nixpkgsFlake = nixpkgs;
            llmAgentsFlake = llm-agents;
            microvmFlake = microvm;
            inherit system;
          }
          // docs;
        };

      treefmtEval = forAllSystems (system: treefmt-nix.lib.evalModule (mkPkgs system) ./treefmt.nix);

      mkProfileEvalCheck =
        system: pkgs: name: args:
        let
          vm = mkVerstakSystem (
            {
              inherit nixpkgs microvm system;
              llmAgents = llm-agents;
              projectRoot = toString self;
              projectName = "verstak-${name}";
              stateDir = "/tmp/verstak-${name}";
            }
            // docs
            // args
          );
          drvPath = builtins.unsafeDiscardStringContext vm.config.microvm.declaredRunner.drvPath;
        in
        pkgs.writeText "verstak-${name}-eval" ''
          ${drvPath}
        '';

      mkLintCheck =
        pkgs: name: nativeBuildInputs: command:
        pkgs.runCommand "verstak-${name}" { inherit nativeBuildInputs; } ''
          cd ${self.outPath}
          ${command}
          touch "$out"
        '';
    in
    {
      lib = {
        inherit mkVerstakSystem;
      };

      nixosModules.default =
        { ... }:
        {
          _module.args = {
            inherit microvm;
            llmAgents = llm-agents;
          };
          imports = [
            microvm.nixosModules.microvm
            ./nix/verstak/options.nix
            ./nix/verstak/core.nix
            ./nix/verstak/modules/networking.nix
            ./nix/verstak/modules/headless-runner.nix
            ./nix/verstak/profiles/headless.nix
            ./nix/verstak/profiles/gui.nix
            ./nix/verstak/profiles/codex.nix
            ./nix/verstak/profiles/claude.nix
          ];
        };

      packages = forAllSystems (system: {
        default = mkLauncher system;
        verstak = mkLauncher system;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
          preCommit = self.checks.${system}.pre-commit;
        in
        {
          default = pkgs.mkShellNoCC {
            packages = devTools pkgs ++ preCommit.enabledPackages;
            shellHook = preCommit.shellHook + ''
              echo "verstak dev shell"
              echo "fmt:      nix fmt"
              echo "check:    nix flake check -L"
              echo "lint:     just lint"
              echo "run:      nix run . -- codex"
              echo "gui:      nix run . -- -p gui codex"
            '';
          };
        }
      );

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      checks = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
          evalCheck = mkProfileEvalCheck system pkgs;
        in
        {
          formatting = treefmtEval.${system}.config.build.check self;

          deadnix = mkLintCheck pkgs "deadnix" [ pkgs.deadnix ] ''
            deadnix --fail .
          '';

          statix = mkLintCheck pkgs "statix" [ pkgs.statix ] ''
            statix check .
          '';

          shellcheck = pkgs.testers.shellcheck {
            name = "verstak-launcher";
            src = ./nix/verstak-launcher.sh;
          };

          pre-commit = git-hooks.lib.${system}.run {
            src = self.outPath;
            hooks = {
              check-added-large-files.enable = true;
              deadnix.enable = true;
              end-of-file-fixer.enable = true;
              nixfmt.enable = true;
              shellcheck.enable = true;
              shfmt = {
                enable = true;
                settings = {
                  indent = 2;
                  simplify = true;
                };
              };
              statix.enable = true;
              trim-trailing-whitespace.enable = true;
            };
          };

          eval-headless = evalCheck "headless" {
            profilesJson = builtins.toJSON [ "headless" ];
            commandJson = builtins.toJSON [ "bash" ];
          };

          eval-gui = evalCheck "gui" {
            profilesJson = builtins.toJSON [ "gui" ];
            commandJson = builtins.toJSON [ "bash" ];
          };

          eval-codex-allowlist = evalCheck "codex-allowlist" {
            profilesJson = builtins.toJSON [
              "headless"
              "codex"
            ];
            commandJson = builtins.toJSON [ "codex" ];
            networkMode = "allowlist";
          };

          eval-codex-internet = evalCheck "codex-internet" {
            profilesJson = builtins.toJSON [
              "headless"
              "codex"
            ];
            commandJson = builtins.toJSON [ "codex" ];
            networkMode = "internet";
          };

          eval-codex-guest-enforcement = evalCheck "codex-guest-enforcement" {
            profilesJson = builtins.toJSON [
              "headless"
              "codex"
            ];
            commandJson = builtins.toJSON [ "codex" ];
            networkMode = "allowlist";
            networkEnforcement = "guest";
          };

          eval-codex-host-guest-firewall = evalCheck "codex-host-guest-firewall" {
            profilesJson = builtins.toJSON [
              "headless"
              "codex"
            ];
            commandJson = builtins.toJSON [ "codex" ];
            networkMode = "allowlist";
            networkEnforcement = "host";
            guestFirewall = true;
          };

          eval-claude = evalCheck "claude" {
            profilesJson = builtins.toJSON [
              "headless"
              "claude"
            ];
            commandJson = builtins.toJSON [ "claude" ];
          };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          meta.description = "Run a command inside the Verstak QEMU MicroVM";
          program = toString self.packages.${system}.default;
        };
      });

      nixosConfigurations.verstak = mkVerstakSystem (
        {
          inherit nixpkgs microvm;
          llmAgents = llm-agents;
          system = "x86_64-linux";
          projectRoot = toString self;
          projectName = "verstak";
          stateDir = "/var/lib/verstak";
          profilesJson = builtins.toJSON [ "headless" ];
          commandJson = builtins.toJSON [ "bash" ];
        }
        // docs
      );
    };
}

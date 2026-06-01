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
              jq
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

      mkAllowlistProxy =
        system:
        let
          pkgs = mkPkgs system;
        in
        pkgs.callPackage ./nix/verstak/allowlist-proxy { };

      mkHostProgramProxy =
        system:
        let
          pkgs = mkPkgs system;
        in
        pkgs.callPackage ./nix/verstak/host-program-proxy { };

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
          runnerDrvPath = builtins.unsafeDiscardStringContext vm.config.microvm.declaredRunner.drvPath;
          networkPolicyDrvPath = builtins.unsafeDiscardStringContext vm.config.system.build.verstakNetworkPolicy.drvPath;
        in
        pkgs.writeText "verstak-${name}-eval" ''
          ${runnerDrvPath}
          ${networkPolicyDrvPath}
        '';

      mkPolicySemanticCheck =
        system: pkgs: name: args: script:
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
          networkPolicy = vm.config.system.build.verstakNetworkPolicy;
        in
        pkgs.runCommand "verstak-${name}-policy" { nativeBuildInputs = [ pkgs.jq ]; } ''
          cp ${networkPolicy} policy.json
          ${script}
          touch "$out"
        '';

      mkHostProgramPolicySemanticCheck =
        system: pkgs: name: args: script:
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
          hostProgramPolicy = vm.config.system.build.verstakHostProgramPolicy;
        in
        pkgs.runCommand "verstak-${name}-host-program-policy" { nativeBuildInputs = [ pkgs.jq ]; } ''
          cp ${hostProgramPolicy} policy.json
          ${script}
          touch "$out"
        '';

      mkCustomPolicySemanticCheck =
        system: pkgs: name: extraModule: script:
        let
          vm = nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = {
              inherit microvm;
              llmAgents = llm-agents;
            };
            modules = [
              microvm.nixosModules.microvm
              ./nix/verstak/options.nix
              ./nix/verstak/core.nix
              ./nix/verstak/modules/networking.nix
              ./nix/verstak/modules/host-programs.nix
              ./nix/verstak/modules/headless-runner.nix
              ./nix/verstak/profiles/headless.nix
              ./nix/verstak/profiles/gui.nix
              ./nix/verstak/profiles/codex.nix
              ./nix/verstak/profiles/claude.nix
              (_: {
                verstak = {
                  projectRoot = toString self;
                  projectName = "verstak-${name}";
                  stateDir = "/tmp/verstak-${name}";
                  mode = "headless";
                  gui.enable = false;
                };
              })
              extraModule
            ];
          };
          networkPolicy = vm.config.system.build.verstakNetworkPolicy;
        in
        pkgs.runCommand "verstak-${name}-policy" { nativeBuildInputs = [ pkgs.jq ]; } ''
          cp ${networkPolicy} policy.json
          ${script}
          touch "$out"
        '';

      mkLintCheck =
        pkgs: name: nativeBuildInputs: command:
        pkgs.runCommand "verstak-${name}" { inherit nativeBuildInputs; } ''
          cd ${self.outPath}
          ${command}
          touch "$out"
        '';

      mkLauncherAliasCheck =
        system: pkgs:
        let
          launcher = mkLauncher system;
        in
        pkgs.runCommand "verstak-openai-alias-rejects-noncodex" { } ''
          set +e
          VERSTAK_NETWORK_MODE=openai ${launcher} bash >stdout.log 2>stderr.log
          status=$?
          set -e
          test "$status" -ne 0
          grep -q "VERSTAK_NETWORK_MODE=openai is only valid with the codex command" stderr.log
          touch "$out"
        '';

      mkLauncherHostProgramsHelpCheck =
        system: pkgs:
        let
          launcher = mkLauncher system;
        in
        pkgs.runCommand "verstak-host-programs-help" { } ''
          ${launcher} --help >stdout.log 2>stderr.log
          grep -q -- "--allow-host-programs" stdout.log
          grep -q -- "--host-programs-policy" stdout.log
          touch "$out"
        '';

      mkLauncherHostProgramsPolicyRejectCheck =
        system: pkgs:
        let
          launcher = mkLauncher system;
        in
        pkgs.runCommand "verstak-host-programs-policy-rejects-unknown" { } ''
          cat >bad-policy-unknown.json <<'JSON'
          {"allow": [], "unexpected": true}
          JSON
          cat >bad-policy-object-rule.json <<'JSON'
          {"allow": [{"program": "git", "argvPrefix": []}], "forbid": []}
          JSON
          cat >bad-policy-empty-rule.json <<'JSON'
          {"allow": ["   "], "forbid": []}
          JSON
          mkdir -p state home
          set +e
          HOME="$PWD/home" VERSTAK_STATE_DIR="$PWD/state" ${launcher} --host-programs-policy bad-policy-unknown.json bash >stdout-unknown.log 2>stderr-unknown.log
          unknown_status=$?
          HOME="$PWD/home" VERSTAK_STATE_DIR="$PWD/state" ${launcher} --host-programs-policy bad-policy-object-rule.json bash >stdout-object.log 2>stderr-object.log
          object_status=$?
          HOME="$PWD/home" VERSTAK_STATE_DIR="$PWD/state" ${launcher} --host-programs-policy bad-policy-empty-rule.json bash >stdout-empty.log 2>stderr-empty.log
          empty_status=$?
          set -e
          test "$unknown_status" -ne 0
          test "$object_status" -ne 0
          test "$empty_status" -ne 0
          grep -q "host-program policy must be a JSON object with only non-empty string allow/forbid arrays" stderr-unknown.log
          grep -q "host-program policy must be a JSON object with only non-empty string allow/forbid arrays" stderr-object.log
          grep -q "host-program policy must be a JSON object with only non-empty string allow/forbid arrays" stderr-empty.log
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
            ./nix/verstak/modules/host-programs.nix
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
        allowlist-proxy = mkAllowlistProxy system;
        host-program-proxy = mkHostProgramProxy system;
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
          policyCheck = mkPolicySemanticCheck system pkgs;
          hostProgramPolicyCheck = mkHostProgramPolicySemanticCheck system pkgs;
          customPolicyCheck = mkCustomPolicySemanticCheck system pkgs;
          launcherAliasCheck = mkLauncherAliasCheck system pkgs;
          launcherHostProgramsHelpCheck = mkLauncherHostProgramsHelpCheck system pkgs;
          launcherHostProgramsPolicyRejectCheck = mkLauncherHostProgramsPolicyRejectCheck system pkgs;
        in
        {
          formatting = treefmtEval.${system}.config.build.check self;

          allowlist-proxy = mkAllowlistProxy system;

          host-program-proxy = mkHostProgramProxy system;

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

          launcher-openai-alias-rejects-noncodex = launcherAliasCheck;

          launcher-host-programs-help = launcherHostProgramsHelpCheck;

          launcher-host-programs-policy-rejects-unknown = launcherHostProgramsPolicyRejectCheck;

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

          eval-codex-allowlist-policy =
            policyCheck "codex-allowlist"
              {
                profilesJson = builtins.toJSON [
                  "headless"
                  "codex"
                ];
                commandJson = builtins.toJSON [ "codex" ];
                networkMode = "allowlist";
              }
              ''
                jq -e '.blockedIPv4Ranges | index("192.0.0.0/8") | not' policy.json
                jq -e '.blockedIPv4Ranges | index("192.0.0.0/24")' policy.json
                jq -e '.blockedIPv4Ranges | index("192.0.2.0/24")' policy.json
                jq -e '.blockedIPv4Ranges | index("192.88.99.0/24")' policy.json
                jq -e '.blockedIPv4Ranges | index("192.168.0.0/16")' policy.json
                jq -e '.allowedDomains | index("openai.com")' policy.json
              '';

          eval-allowlist-domain-normalization =
            customPolicyCheck "allowlist-domain-normalization"
              (_: {
                verstak.network = {
                  mode = "allowlist";
                  allowedDomains = [
                    " API.OpenAI.Com. "
                    "chatgpt.com:443"
                  ];
                };
              })
              ''
                jq -e '.allowedDomains == ["api.openai.com", "chatgpt.com"]' policy.json
              '';

          eval-host-program-policy =
            hostProgramPolicyCheck "host-program-policy"
              {
                hostProgramsJson = builtins.toJSON [ "git" ];
                hostProgramsPolicyJson = builtins.toJSON {
                  allow = [ "gh" ];
                  forbid = [ "git push" ];
                };
              }
              ''
                jq -e '.allow == ["git","gh"]' policy.json
                jq -e '.forbid == ["git push"]' policy.json
                jq -e '.projectMount == "/workspace/project"' policy.json
                jq -e '.auditLog | test("/tmp/verstak-host-program-policy/host-programs/audit.jsonl$")' policy.json
              '';

          eval-codex-internet = evalCheck "codex-internet" {
            profilesJson = builtins.toJSON [
              "headless"
              "codex"
            ];
            commandJson = builtins.toJSON [ "codex" ];
            networkMode = "internet";
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

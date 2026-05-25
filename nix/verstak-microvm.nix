{ nixpkgs, microvm, llmAgents ? null, system ? builtins.currentSystem
, projectRoot ? builtins.getEnv "PWD"
, projectName ? builtins.baseNameOf (toString projectRoot)
, projectMount ? "/workspace/project", stateDir, vmUser ? "steve"
, vmGroup ? null, vmUid ? 1000, vmGid ? 1000, vmHome ? null
, profilesJson ? ''["headless"]'', commandJson ? ''["bash"]''
, extraFlakesJson ? "[]", useDevshell ? false, devshellRef ? projectMount
, oneShot ? false, memMb ? 8192, codexAppServerPort ? 4500
, codexAppServerHostAddress ? "127.0.0.1", storeOverlaySizeMb ? 4096
, tmpfsSize ? "1G", agentBasePath ? ../agents/vm-base.md
, agentGuiPath ? ../agents/vm-gui.md
, agentHeadlessPath ? ../agents/vm-headless.md
, guiSkillPath ? ../skills/vm-gui/SKILL.md, }:

let
  lib = nixpkgs.lib;

  profiles = lib.unique (builtins.fromJSON profilesJson);
  command = builtins.fromJSON commandJson;
  extraFlakeRefs = builtins.fromJSON extraFlakesJson;
  extraFlakes = map builtins.getFlake extraFlakeRefs;
  builtinProfileNames = [ "headless" "gui" "codex" ];

  externalProfileModules = name:
    lib.concatMap (flake:
      lib.optional
      (flake ? verstakProfiles && builtins.hasAttr name flake.verstakProfiles)
      flake.verstakProfiles.${name} ++ lib.optional
      (flake ? nixosModules && builtins.hasAttr name flake.nixosModules)
      flake.nixosModules.${name}) extraFlakes;

  profileModule = name:
    if lib.elem name builtinProfileNames then
      [ ]
    else
      let matches = externalProfileModules name;
      in if matches != [ ] then
        [ (builtins.head matches) ]
      else
        throw "unknown Verstak profile '${name}'";

  selectedExternalProfileModules = lib.concatMap profileModule profiles;

  adapterModule = { ... }: {
    verstak = {
      inherit profiles projectName projectMount stateDir;
      projectRoot = projectRoot;

      vm = {
        user = vmUser;
        group = vmGroup;
        uid = vmUid;
        gid = vmGid;
        home = vmHome;
      };

      command = {
        argv = command;
        inherit useDevshell devshellRef oneShot;
      };

      gui.enable = lib.elem "gui" profiles;
      codex.enable = lib.elem "codex" profiles;
      codex.appServer = {
        port = codexAppServerPort;
        hostAddress = codexAppServerHostAddress;
      };

      resources = {
        memoryMb = memMb;
        inherit storeOverlaySizeMb tmpfsSize;
      };

      docs = {
        inherit agentBasePath agentGuiPath agentHeadlessPath guiSkillPath;
      };
    };
  };
in lib.nixosSystem {
  inherit system;
  specialArgs = { inherit microvm llmAgents; };
  modules = [
    microvm.nixosModules.microvm
    ./verstak/options.nix
    ./verstak/core.nix
    ./verstak/modules/headless-runner.nix
    ./verstak/profiles/headless.nix
    ./verstak/profiles/gui.nix
    ./verstak/profiles/codex.nix
    adapterModule
  ] ++ selectedExternalProfileModules;
}

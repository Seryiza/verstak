{
  nixpkgs,
  microvm,
  llmAgents ? null,
  system ? builtins.currentSystem,
  projectRoot ? builtins.getEnv "PWD",
  projectName ? builtins.baseNameOf (toString projectRoot),
  projectMount ? "/workspace/project",
  stateDir,
  vmUser ? "steve",
  vmGroup ? null,
  vmUid ? 1000,
  vmGid ? 1000,
  vmHome ? null,
  mode ? null,
  profilesJson ? ''["headless"]'',
  commandJson ? ''["bash"]'',
  extraFlakesJson ? "[]",
  useDevshell ? false,
  devshellRef ? projectMount,
  oneShot ? false,
  memMb ? 8192,
  ttyRows ? 40,
  ttyColumns ? 120,
  codexAppServerPort ? 4500,
  codexAppServerHostAddress ? "127.0.0.1",
  networkMode ? "deny",
  storeOverlaySizeMb ? 4096,
  tmpfsSize ? "1G",
  agentBasePath ? ../agents/vm-base.md,
  agentGuiPath ? ../agents/vm-gui.md,
  agentHeadlessPath ? ../agents/vm-headless.md,
  guiSkillPath ? ../skills/vm-gui/SKILL.md,
}:

let
  inherit (nixpkgs) lib;

  rawProfiles = lib.unique (builtins.fromJSON profilesJson);
  modeProfileNames = [
    "headless"
    "gui"
  ];
  profiles = lib.subtractLists modeProfileNames rawProfiles;
  selectedMode =
    if mode != null then
      mode
    else if lib.elem "gui" rawProfiles then
      "gui"
    else
      "headless";
  command = builtins.fromJSON commandJson;
  extraFlakeRefs = builtins.fromJSON extraFlakesJson;
  extraFlakes = map builtins.getFlake extraFlakeRefs;
  builtinProfileNames = [
    "codex"
    "claude"
  ];

  externalProfileModules =
    name:
    lib.concatMap (
      flake:
      lib.optional (
        flake ? verstakProfiles && builtins.hasAttr name flake.verstakProfiles
      ) flake.verstakProfiles.${name}
      ++ lib.optional (
        flake ? nixosModules && builtins.hasAttr name flake.nixosModules
      ) flake.nixosModules.${name}
    ) extraFlakes;

  profileModule =
    name:
    if lib.elem name builtinProfileNames then
      [ ]
    else
      let
        matches = externalProfileModules name;
      in
      if matches != [ ] then [ (builtins.head matches) ] else throw "unknown Verstak profile '${name}'";

  selectedExternalProfileModules = lib.concatMap profileModule profiles;

  adapterModule = _: {
    verstak = {
      inherit
        profiles
        projectName
        projectMount
        projectRoot
        stateDir
        ;

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

      mode = selectedMode;
      gui.enable = selectedMode == "gui";
      codex.enable = lib.elem "codex" profiles;
      claude.enable = lib.elem "claude" profiles;
      codex.appServer = {
        port = codexAppServerPort;
        hostAddress = codexAppServerHostAddress;
      };

      network.mode = networkMode;

      terminal = {
        rows = ttyRows;
        columns = ttyColumns;
      };

      resources = {
        memoryMb = memMb;
        inherit storeOverlaySizeMb tmpfsSize;
      };

      docs = {
        inherit
          agentBasePath
          agentGuiPath
          agentHeadlessPath
          guiSkillPath
          ;
      };
    };
  };
in
lib.nixosSystem {
  inherit system;
  specialArgs = { inherit microvm llmAgents; };
  modules = [
    microvm.nixosModules.microvm
    ./verstak/options.nix
    ./verstak/core.nix
    ./verstak/modules/networking.nix
    ./verstak/modules/headless-runner.nix
    ./verstak/profiles/headless.nix
    ./verstak/profiles/gui.nix
    ./verstak/profiles/codex.nix
    ./verstak/profiles/claude.nix
    adapterModule
  ]
  ++ selectedExternalProfileModules;
}

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.verstak;
  hostProgramProxy = pkgs.callPackage ../host-program-proxy { };
  hostProgramsEnabled = cfg.hostPrograms.allow != [ ];
  ruleTokens =
    rule:
    builtins.filter (token: builtins.isString token && token != "") (
      builtins.split "[[:space:]]+" (lib.trim rule)
    );
  parseRule =
    rule:
    let
      tokens = ruleTokens rule;
    in
    if tokens == [ ] then
      throw "verstak.hostPrograms rules must not be empty"
    else
      {
        program = builtins.head tokens;
      };
  allowRules = map parseRule cfg.hostPrograms.allow;
  forbidRules = map parseRule cfg.hostPrograms.forbid;
  allRules = allowRules ++ forbidRules;
  validProgramName =
    name: name != "." && name != ".." && builtins.match "[A-Za-z0-9._+-]+" name != null;
  invalidProgramNames = lib.filter (name: name != "" && !validProgramName name) (
    map (rule: rule.program) allRules
  );
  programNames = lib.unique (lib.filter (name: name != "") (map (rule: rule.program) allowRules));
  proxyAddress = "${cfg.internal.hostProgramGuestAddress}:${toString cfg.internal.hostProgramGuestPort}";
  auditLog = "${cfg.stateDir}/host-programs/audit.jsonl";
  hostProgramPolicy = {
    allow = map lib.trim cfg.hostPrograms.allow;
    forbid = map lib.trim cfg.hostPrograms.forbid;
    projectRoot = toString cfg.projectRoot;
    inherit (cfg) projectMount;
    inherit auditLog;
  };
  hostProgramPolicyFile = pkgs.writeText "verstak-host-program-policy.json" (
    builtins.toJSON hostProgramPolicy
  );
  stubLine =
    program:
    "exec ${hostProgramProxy}/bin/verstak-host-program-client --program ${lib.escapeShellArg program} --addr ${lib.escapeShellArg proxyAddress} -- \"$@\"";
  stubPackage = pkgs.runCommand "verstak-host-program-stubs" { } (
    ''
      mkdir -p "$out/bin"
    ''
    + lib.concatMapStringsSep "\n" (program: ''
      printf '%s\n' ${
        lib.escapeShellArgs [
          "#!${pkgs.runtimeShell}"
          (stubLine program)
        ]
      } > "$out/bin/${program}"
      chmod +x "$out/bin/${program}"
    '') programNames
  );
  localBinStubRules = map (
    program: "L+ ${cfg.internal.vmUserHome}/.local/bin/${program} - - - - ${stubPackage}/bin/${program}"
  ) programNames;
in
{
  assertions = [
    {
      assertion = invalidProgramNames == [ ];
      message = "verstak.hostPrograms rule names must be simple host PATH names matching [A-Za-z0-9._+-]+; invalid: ${lib.concatStringsSep ", " invalidProgramNames}";
    }
  ];

  system.build.verstakHostProgramPolicy = hostProgramPolicyFile;

  systemd.tmpfiles.rules = lib.mkIf hostProgramsEnabled localBinStubRules;

  verstak.internal.hostProgramGuestFwds = lib.mkIf hostProgramsEnabled [
    "guestfwd=tcp:${cfg.internal.hostProgramGuestAddress}:${toString cfg.internal.hostProgramGuestPort}-cmd:${hostProgramProxy}/bin/verstak-host-program-proxy ${hostProgramPolicyFile}"
  ];
}

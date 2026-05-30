{ config }:

let
  cfg = config.verstak;
  modeInstructions = if cfg.internal.isGui then cfg.docs.agentGuiPath else cfg.docs.agentHeadlessPath;
in
{
  mkAgentText =
    profileInstructions:
    builtins.readFile cfg.docs.agentBasePath
    + "\n\n"
    + builtins.readFile modeInstructions
    + profileInstructions;
}

_:

{
  projectRootFile = "flake.nix";

  programs = {
    nixfmt.enable = true;
    gofmt.enable = true;

    shfmt = {
      enable = true;
      indent_size = 2;
      simplify = true;
    };
  };
}

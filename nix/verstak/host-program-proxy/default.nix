{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "verstak-host-program-proxy";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;
  subPackages = [
    "cmd/proxy"
    "cmd/client"
  ];

  env.CGO_ENABLED = "0";

  ldflags = [
    "-s"
    "-w"
  ];

  postInstall = ''
    mv "$out/bin/proxy" "$out/bin/verstak-host-program-proxy"
    mv "$out/bin/client" "$out/bin/verstak-host-program-client"
  '';

  meta = {
    description = "Host-side Verstak command proxy and guest client for allowed host programs";
    mainProgram = "verstak-host-program-client";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}

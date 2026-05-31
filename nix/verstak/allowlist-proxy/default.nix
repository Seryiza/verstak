{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "verstak-allowlist-proxy";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;
  subPackages = [ "." ];

  env.CGO_ENABLED = "0";

  ldflags = [
    "-s"
    "-w"
  ];

  postInstall = ''
    mv "$out/bin/allowlist-proxy" "$out/bin/verstak-allowlist-proxy"
  '';

  meta = {
    description = "Host-side Verstak allowlist proxy for QEMU guestfwd connections";
    mainProgram = "verstak-allowlist-proxy";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}

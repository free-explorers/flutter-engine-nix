# Non-flake entry point. The nixpkgs pin lives in flake.lock: fetching the
# locked revision by its narHash gives the same store path as the flake input.
{
  flutterVersion,
  system ? builtins.currentSystem,
  runtimeMode ? "release",
  isOptimized ? runtimeMode != "debug",
}:
let
  locked = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked;
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/${locked.owner}/${locked.repo}/archive/${locked.rev}.tar.gz";
    sha256 = locked.narHash;
  };
in
import ./packages.nix {
  nixpkgsRevision = locked.rev;
  inherit
    nixpkgs
    system
    flutterVersion
    runtimeMode
    isOptimized
    ;
}

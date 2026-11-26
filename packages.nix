# The engine set for one nixpkgs source. flake.nix passes the flake's nixpkgs
# input and default.nix fetches the same revision from flake.lock; both are the
# same store path, and it is imported here the same way for both, without the
# user's nixpkgs configuration or overlays, so the derivations are identical
# and the cache serves either.
{
  nixpkgs,
  nixpkgsRevision,
  system,
  flutterVersion,
  runtimeMode ? "release",
  isOptimized ? runtimeMode != "debug",
}:
let
  pkgs = import nixpkgs {
    inherit system;
    config = { };
    overlays = [ ];
  };
  engine = pkgs.callPackage ./engine.nix { inherit flutterVersion runtimeMode isOptimized; };
  runtime = pkgs.callPackage ./runtime.nix { inherit engine; };
  aot = pkgs.callPackage ./aot.nix { inherit engine runtime; };
in
{
  inherit
    flutterVersion
    nixpkgsRevision
    engine
    runtime
    aot
    ;
  rawEngine = engine;
  dynamicLinker = pkgs.stdenv.cc.bintools.dynamicLinker;
}

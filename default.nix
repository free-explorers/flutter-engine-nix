{
  flutterVersion ? (builtins.fromJSON (builtins.readFile ./default.json)).flutterVersion,
  system ? builtins.currentSystem,
  runtimeMode ? "release",
  isOptimized ? runtimeMode != "debug",
}:
let
  nixpkgsRevision = "26f4107e47e3ad0ffd0db220469ba83b6f6d96e8";
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRevision}.tar.gz";
    sha256 = "sha256-OaQwAtPMTjQiY2sT/2/62UbSPhzP/0aDnWzMm/NCiUw=";
  };
  pkgs = import nixpkgs { inherit system; };
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

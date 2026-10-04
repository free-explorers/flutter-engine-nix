{
  flutterVersion ? (builtins.fromJSON (builtins.readFile ./default.json)).flutterVersion,
  system ? builtins.currentSystem,
}:
let
  nixpkgsRevision = "774debe7a0d1b496e35677ad955a1011c6ff74f3";
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRevision}.tar.gz";
    sha256 = "1japvhk1jlgc8sihm9gczwnv6fjanqsr1ji57vx67wbvqj88a34x";
  };
  pkgs = import nixpkgs { inherit system; };
  engine = pkgs.callPackage ./engine.nix { inherit flutterVersion; };
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

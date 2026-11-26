{
  description = "Pinned Nix source build of the Flutter release engine";

  # The engine is published to the veshell Cachix cache for the locked
  # revision only: a consumer that makes this input follow another nixpkgs
  # builds the engine from source.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    {
      # The engine set for a Flutter version from engine-source.json, with the
      # same attributes as default.nix.
      lib.engineFor =
        {
          flutterVersion,
          system ? "x86_64-linux",
          runtimeMode ? "release",
          isOptimized ? runtimeMode != "debug",
        }:
        import ./packages.nix {
          nixpkgsRevision = nixpkgs.rev;
          inherit
            nixpkgs
            system
            flutterVersion
            runtimeMode
            isOptimized
            ;
        };
    };
}

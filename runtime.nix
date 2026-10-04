{
  lib,
  stdenv,
  autoPatchelfHook,
  patchelf,
  zlib,
  fontconfig,
  engine,
  gtk3,
  clang,
  llvmPackages,
  symlinkJoin,
}:
stdenv.mkDerivation {
  pname = "flutter-engine-runtime";
  inherit (engine) version;
  dontUnpack = true;
  dontStrip = true;
  strictDeps = true;
  nativeBuildInputs = [
    autoPatchelfHook
    patchelf
  ];
  buildInputs = [
    stdenv.cc.cc.lib
    zlib
    fontconfig
  ];
  # Enforce separation, including accidental references left in the ELF RPATH.
  disallowedRequisites = [
    engine
    engine.toolchain
    stdenv.cc
    stdenv.cc.cc
    gtk3
    clang
    clang.cc
    llvmPackages.llvm
    (symlinkJoin {
      name = "llvm";
      paths = [
        clang
        llvmPackages.llvm
      ];
    })
  ];
  installPhase = ''
    runHook preInstall
    install -Dm755 ${engine}/out/host_release/libflutter_engine.so "$out/lib/libflutter_engine.so"
    install -Dm644 ${engine}/out/host_release/flutter_embedder.h "$out/include/flutter_embedder.h"
    install -Dm644 ${engine}/out/host_release/icudtl.dat "$out/share/flutter/icudtl.dat"
    ln -s ../share/flutter/icudtl.dat "$out/lib/icudtl.dat"
    # Never retain the full build output's toolchain/GTK search paths.
    patchelf --set-rpath "" "$out/lib/libflutter_engine.so"
    runHook postInstall
  '';
  meta = {
    description = "Standalone Flutter embedder runtime, header and ICU data";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
  };
}

# Synthetic compiler/ELF loader smoke test, not a rendering or application test.
{
  runCommand,
  writeText,
  stdenv,
  engine,
  runtime,
}:
let
  localEngine = "${engine}/out/host_release";
  main = writeText "engine-aot-main.dart" ''
    import 'dart:ui';
    @pragma('vm:entry-point')
    void main() {
      print(PlatformDispatcher.instance.views.length);
    }
  '';
  loader = writeText "engine-aot-loader.c" ''
    #include <stdio.h>
    #include "flutter_embedder.h"
    int main(int argc, char **argv) {
      if (argc != 2 || !FlutterEngineRunsAOTCompiledDartCode()) return 1;
      FlutterEngineAOTDataSource source = {
        .type = kFlutterEngineAOTDataSourceTypeElfPath,
        .elf_path = argv[1],
      };
      FlutterEngineAOTData data = NULL;
      FlutterEngineResult result = FlutterEngineCreateAOTData(&source, &data);
      if (result != kSuccess || data == NULL) {
        fprintf(stderr, "FlutterEngineCreateAOTData failed: %d\n", result);
        return 1;
      }
      return FlutterEngineCollectAOTData(data) == kSuccess ? 0 : 1;
    }
  '';
in
runCommand "flutter-engine-aot-test-${engine.version}"
  {
    nativeBuildInputs = [ stdenv.cc ];
  }
  ''
    ${localEngine}/dart-sdk/bin/dartaotruntime \
      ${localEngine}/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot \
      --sdk-root=${localEngine}/flutter_patched_sdk_product \
      --target=flutter --target-os=linux --aot --tfa \
      -Ddart.vm.product=true -Ddart.vm.profile=false --output-dill=app.dill ${main}
    test -s app.dill
    ${localEngine}/gen_snapshot --deterministic --snapshot_kind=app-aot-elf --elf=libapp.so app.dill
    $CC -std=c11 -I${runtime}/include ${loader} \
      -L${runtime}/lib -Wl,-rpath,${runtime}/lib -lflutter_engine -o aot-loader
    ./aot-loader "$PWD/libapp.so"
    mkdir -p "$out"
    cp libapp.so "$out/libapp.so"
  ''

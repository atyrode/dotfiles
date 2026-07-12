{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "code-tui";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  vendorHash = "sha256-Ldy6/HYzMlF3FpviWzM1PLUgfuBkMuynQjXSMErJeEQ=";

  # The launcher picker is invoked as `code`.
  postInstall = ''
    mv "$out/bin/code-tui" "$out/bin/code"
  '';

  meta = {
    description = "Bubble Tea launcher picker for the managed omp profiles";
    mainProgram = "code";
  };
}

{
  lib,
  omp,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "omp-agents";
  version = lib.getVersion omp;

  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" bundled
    ${lib.getExe omp} agents unpack --dir "$PWD/bundled" --force

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    agents_dir="$out/share/omp/agents"
    mkdir -p "$agents_dir"
    cp bundled/*.md "$agents_dir/"

    test "$(find "$agents_dir" -maxdepth 1 -name '*.md' | wc -l)" -eq 6

    runHook postInstall
  '';

  meta = {
    description = "Pinned OMP bundled agents unpacked from the pinned binary";
    license = lib.licenses.mit;
    platforms = omp.meta.platforms;
  };
}

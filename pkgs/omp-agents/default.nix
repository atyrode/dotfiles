{
  lib,
  omp,
  patch,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "omp-agents";
  version = lib.getVersion omp;

  dontUnpack = true;
  nativeBuildInputs = [ patch ];

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" bundled
    ${lib.getExe omp} agents unpack --dir "$PWD/bundled" --force
    patch -d bundled -p1 < ${../../omp/agents/escalation.patch}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    agents_dir="$out/share/omp/agents"
    mkdir -p "$agents_dir"
    cp bundled/*.md "$agents_dir/"
    cp ${../../omp/agents/deep}/*.md "$agents_dir/"

    test "$(find "$agents_dir" -maxdepth 1 -name '*.md' | wc -l)" -eq 13

    runHook postInstall
  '';

  meta = {
    description = "Pinned OMP bundled agents with atyrode escalation agents and prompts";
    license = lib.licenses.mit;
    platforms = omp.meta.platforms;
  };
}

{
  bun,
  fetchurl,
  jq,
  lib,
  makeWrapper,
  src,
  stdenvNoCC,
}:

let
  sourceRevision =
    src.rev or (throw "manifold-action-runner requires a revision-pinned source input");
  zodVersion = "4.4.3";
  zod = fetchurl {
    url = "https://registry.npmjs.org/zod/-/zod-${zodVersion}.tgz";
    hash = "sha512-ytENFjIJFl2UwYglde2jchW2Hwm4GJFLDiSXWdTrJQBIN9Fcyp7n4DhxJEiWNAJMV1/BqWfW/kkg71UDcHJyTQ==";
  };
in
assert lib.assertMsg (
  builtins.match "[0-9a-f]{40}" sourceRevision != null
) "manifold-action-runner requires a full Git source revision";
assert lib.assertMsg (lib.versionAtLeast bun.version "1.4.2")
  "manifold-action-runner requires Bun >= 1.4.2";
stdenvNoCC.mkDerivation {
  pname = "manifold-action-runner";
  version = "0-unstable-${builtins.substring 0 12 sourceRevision}";
  inherit src;

  nativeBuildInputs = [
    bun
    jq
    makeWrapper
  ];

  # Only the supported SDK entrypoint's dependency closure is assembled. Do not
  # install the workspace or reintroduce its mutable Bun-dependency FOD.
  buildPhase = ''
    runHook preBuild

    for manifest in packages/sdk/package.json packages/protocol/package.json; do
      if ! jq -e --arg version '${zodVersion}' '.dependencies.zod == $version' "$manifest" >/dev/null; then
        echo "manifold-action-runner: $manifest disagrees with the vendored Zod version" >&2
        exit 1
      fi
    done
    mkdir -p node_modules/zod node_modules/@manifold
    tar -xzf ${zod} --strip-components=1 -C node_modules/zod
    jq -e --arg version '${zodVersion}' '.version == $version' node_modules/zod/package.json >/dev/null
    ln -s ../../packages/protocol node_modules/@manifold/protocol

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bun build packages/sdk/src/action-runner-main.ts \
      --target=bun --outfile=manifold-action-runner.js

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 manifold-action-runner.js "$out/libexec/manifold-action-runner.js"
    install -Dm644 LICENSE "$out/share/licenses/manifold-action-runner/LICENSE"
    install -Dm644 node_modules/zod/LICENSE "$out/share/licenses/manifold-action-runner/ZOD-LICENSE"
    mkdir -p "$out/share/manifold-action-runner"
    printf '%s\n' '${sourceRevision}' > "$out/share/manifold-action-runner/source-revision"
    makeWrapper ${lib.getExe bun} "$out/bin/manifold-action-runner" \
      --add-flags "--no-install $out/libexec/manifold-action-runner.js"

    runHook postInstall
  '';

  passthru = { inherit sourceRevision; };

  meta = {
    description = "Maintained Manifold SDK harness-bound action-plane JSONL runner";
    homepage = "https://github.com/atyrode/manifold";
    license = lib.licenses.mit;
    mainProgram = "manifold-action-runner";
    platforms = bun.meta.platforms;
  };
}

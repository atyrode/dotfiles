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
  # The protocol loads its credential-enrollment crypto lazily from
  # @hpke/core, which a source declares from v0.34.0 on; @hpke/common is
  # that package's one dependency, at the version Manifold's bun.lock resolves.
  hpkeCoreVersion = "1.9.0";
  hpkeCore = fetchurl {
    url = "https://registry.npmjs.org/@hpke/core/-/core-${hpkeCoreVersion}.tgz";
    hash = "sha512-pFxWl1nNJeQCSUFs7+GAblHvXBCjn9EPN65vdKlYQil2aURaRxfGMO6vBKGqm1YHTKwiAxJQNEI70PbSowMP9Q==";
  };
  hpkeCommonVersion = "1.10.1";
  hpkeCommon = fetchurl {
    url = "https://registry.npmjs.org/@hpke/common/-/common-${hpkeCommonVersion}.tgz";
    hash = "sha512-moJwhmtLtuxiUzzNp1jpfBfx8yefKoO9D/RCR9dmwrnc7qjJqId1rEtQz+lSlU5cabX8daToMSx/7HayXOiaFw==";
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
    if ! jq -e --arg version '${hpkeCoreVersion}' '(.dependencies["@hpke/core"] // $version) == $version' packages/protocol/package.json >/dev/null; then
      echo "manifold-action-runner: packages/protocol/package.json disagrees with the vendored @hpke/core version" >&2
      exit 1
    fi
    mkdir -p node_modules/zod node_modules/@manifold node_modules/@hpke/core node_modules/@hpke/common
    tar -xzf ${zod} --strip-components=1 -C node_modules/zod
    tar -xzf ${hpkeCore} --strip-components=1 -C node_modules/@hpke/core
    tar -xzf ${hpkeCommon} --strip-components=1 -C node_modules/@hpke/common
    jq -e --arg version '${zodVersion}' '.version == $version' node_modules/zod/package.json >/dev/null
    jq -e --arg version '${hpkeCoreVersion}' '.version == $version' node_modules/@hpke/core/package.json >/dev/null
    jq -e --arg version '${hpkeCommonVersion}' '.version == $version' node_modules/@hpke/common/package.json >/dev/null
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
    install -Dm644 node_modules/@hpke/core/LICENSE "$out/share/licenses/manifold-action-runner/HPKE-CORE-LICENSE"
    install -Dm644 node_modules/@hpke/common/LICENSE "$out/share/licenses/manifold-action-runner/HPKE-COMMON-LICENSE"
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

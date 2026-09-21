{
  jq,
  lib,
  makeWrapper,
  manifold-action-runner,
  src,
  stdenvNoCC,
}:

let
  sourceRevision = src.rev or (throw "babel-recall requires a revision-pinned source input");
in
assert lib.assertMsg (
  builtins.match "[0-9a-f]{40}" sourceRevision != null
) "babel-recall requires a full Git source revision";
stdenvNoCC.mkDerivation {
  pname = "babel-recall";
  version = "0-unstable-${builtins.substring 0 12 sourceRevision}";
  inherit src;

  nativeBuildInputs = [
    jq
    makeWrapper
  ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # The approvals are generated against this exact SDK, not a compatible
    # version range. Compare the installed runner's provenance before packaging.
    expectedRevision="$(cat MANIFOLD_REV)"
    runnerRevision="$(cat ${manifold-action-runner}/share/manifold-action-runner/source-revision)"
    if [ "$expectedRevision" != "$runnerRevision" ]; then
      echo "babel-recall: MANIFOLD_REV does not match the packaged action runner" >&2
      exit 1
    fi
    jq -e 'type == "array"' babel/recall-profile.json >/dev/null

    install -Dm644 babel/recall-skill.md "$out/share/agent-skills/babel-recall/SKILL.md"
    install -Dm644 babel/recall-profile.json "$out/share/babel-recall/read-results.json"
    install -Dm644 LICENSE "$out/share/licenses/babel-recall/LICENSE"

    # Embed only the immutable, non-secret approvals. All Agent/run binding is
    # inherited from the trusted launcher; the SDK owns refusal and cleanup.
    makeWrapper ${lib.getExe manifold-action-runner} "$out/bin/babel-recall-runner" \
      --set MANIFOLD_READ_RESULTS "$(cat "$out/share/babel-recall/read-results.json")"

    runHook postInstall
  '';

  passthru = {
    inherit sourceRevision manifold-action-runner;
  };

  meta = {
    description = "Version-bound Babel Recall skill and Manifold SDK runner profile";
    homepage = "https://github.com/atyrode/babel";
    license = lib.licenses.mit;
    mainProgram = "babel-recall-runner";
    platforms = manifold-action-runner.meta.platforms;
  };
}

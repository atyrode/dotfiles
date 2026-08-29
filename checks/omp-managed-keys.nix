{
  lib,
  ompConfigured,
  pkgs,
}:

let
  # `omp config set/get` refuses to touch a managed key by consulting these
  # hand-written path lists. They are a mirror of the YAML Nix actually
  # enforces, and nothing else proves the two agree: a key added to
  # omp/defaults.yml but forgotten here is silently writable, so the operator
  # edits a value that Nix overrides on the next launch with no error anywhere.
  layers = [
    {
      name = "defaults";
      config = ompConfigured.passthru.defaultsConfig;
      paths = ompConfigured.passthru.managedDefaultPaths;
      attribute = "managedDefaultPaths";
    }
    {
      name = "policy";
      config = ompConfigured.passthru.policyConfig;
      paths = ompConfigured.passthru.enforcedPolicyPaths;
      attribute = "enforcedPolicyPaths";
    }
  ];

  # A managed path may name a leaf ("retry.enabled") or a whole subtree
  # ("modelRoles", "task.agentModelOverrides"), so a YAML leaf counts as
  # covered when some managed path equals it or is a dotted prefix of it.
  compare = ''
    ($nixPaths | split("\n") | map(select(length > 0))) as $managed
    | [ paths(scalars) | map(tostring) | join(".") ] as $leaves
    | [ paths | map(tostring) | join(".") ] as $all
    | {
        uncovered: [
          $leaves[]
          | select(
              . as $key
              | ($managed | map(. as $p | $key == $p or ($key | startswith($p + "."))) | any)
              | not
            )
        ],
        stale: [ $managed[] | select(. as $p | ($all | index($p)) == null) ]
      }
  '';

  checkLayer = layer: ''
    yq -o=json '.' ${layer.config} > "$TMPDIR/${layer.name}.json"
    printf '%s' ${lib.escapeShellArg (lib.concatStringsSep "\n" layer.paths)} \
      > "$TMPDIR/${layer.name}.paths"

    result="$(jq -c --rawfile nixPaths "$TMPDIR/${layer.name}.paths" \
      ${lib.escapeShellArg compare} "$TMPDIR/${layer.name}.json")"

    uncovered="$(jq -r '.uncovered | join(", ")' <<<"$result")"
    stale="$(jq -r '.stale | join(", ")' <<<"$result")"

    if [ -n "$uncovered" ]; then
      echo "omp/${layer.name}.yml sets keys that ${layer.attribute} does not cover: $uncovered" >&2
      echo "add them to ${layer.attribute} in pkgs/omp-configured/default.nix, or omp config set will accept edits Nix overrides" >&2
      failed=1
    fi
    if [ -n "$stale" ]; then
      echo "${layer.attribute} lists paths absent from omp/${layer.name}.yml: $stale" >&2
      failed=1
    fi
  '';
in
pkgs.runCommand "check-omp-managed-keys"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.yq-go
    ];
  }
  ''
    failed=0
    ${lib.concatMapStrings checkLayer layers}
    [ "$failed" -eq 0 ] || exit 1
    mkdir "$out"
  ''

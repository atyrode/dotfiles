# Verify that repository-pinned macOS apps keep their upstream Developer ID
# signatures (nixpkgs Darwin fixup would replace them with ad-hoc ones; the
# overlay skips fixup, and these checks prove the preserved identity, #89).
{
  pkgs,
  apps,
}:

let
  mkSignatureCheck =
    {
      name,
      app,
      bundleId,
      teamId,
      package,
    }:
    pkgs.runCommand "check-${name}"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.rcodesign
          pkgs.yq-go
        ];
      }
      ''
        rcodesign --config-file /dev/null print-signature-info \
          ${package}/Applications/${app}.app/Contents/MacOS/${app} \
          > signature.yml

        # rcodesign calls the CodeDirectory TeamIdentifier field team_name.
        yq --exit-status '
          [
            .[]
            | .entity.mach_o.signature.code_directory
            | select(. != null)
          ]
          | (
              (length > 0)
              and all_c(
                (.identifier == "${bundleId}")
                and (.team_name == "${teamId}")
              )
            )
        ' signature.yml >/dev/null

        # The signing identifier above is the CodeDirectory field; assert the app
        # bundle's own CFBundleIdentifier independently (#89 also observed the
        # broken state unbinding Info.plist from the signature).
        python3 - <<'EOF'
        import plistlib
        import sys

        with open(
            "${package}/Applications/${app}.app/Contents/Info.plist", "rb"
        ) as plist_file:
            plist = plistlib.load(plist_file)

        bundle_identifier = plist.get("CFBundleIdentifier")
        if bundle_identifier != "${bundleId}":
            sys.exit(f"CFBundleIdentifier is {bundle_identifier!r}, expected '${bundleId}'")
        EOF

        mkdir "$out"
      '';
in
builtins.listToAttrs (
  map (spec: {
    inherit (spec) name;
    value = mkSignatureCheck spec;
  }) apps
)

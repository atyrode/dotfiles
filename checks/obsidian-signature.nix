{ pkgs, obsidian }:

pkgs.runCommand "check-obsidian-signature"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.rcodesign
      pkgs.yq-go
    ];
  }
  ''
    rcodesign --config-file /dev/null print-signature-info \
      ${obsidian}/Applications/Obsidian.app/Contents/MacOS/Obsidian \
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
            (.identifier == "md.obsidian")
            and (.team_name == "6JSW4SJWN9")
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
        "${obsidian}/Applications/Obsidian.app/Contents/Info.plist", "rb"
    ) as plist_file:
        plist = plistlib.load(plist_file)

    bundle_identifier = plist.get("CFBundleIdentifier")
    if bundle_identifier != "md.obsidian":
        sys.exit(f"CFBundleIdentifier is {bundle_identifier!r}, expected 'md.obsidian'")
    EOF

    mkdir "$out"
  ''

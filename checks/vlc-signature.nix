{ pkgs, vlc-bin }:

pkgs.runCommand "check-vlc-signature"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.rcodesign
      pkgs.yq-go
    ];
  }
  ''
    rcodesign --config-file /dev/null print-signature-info \
      ${vlc-bin}/Applications/VLC.app/Contents/MacOS/VLC \
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
            (.identifier == "org.videolan.vlc")
            and (.team_name == "75GAHG3SZQ")
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
        "${vlc-bin}/Applications/VLC.app/Contents/Info.plist", "rb"
    ) as plist_file:
        plist = plistlib.load(plist_file)

    bundle_identifier = plist.get("CFBundleIdentifier")
    if bundle_identifier != "org.videolan.vlc":
        sys.exit(f"CFBundleIdentifier is {bundle_identifier!r}, expected 'org.videolan.vlc'")
    EOF

    mkdir "$out"
  ''

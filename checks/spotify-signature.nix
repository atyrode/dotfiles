{ pkgs, spotify }:

pkgs.runCommand "check-spotify-signature"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.rcodesign
      pkgs.yq-go
    ];
  }
  ''
    rcodesign --config-file /dev/null print-signature-info \
      ${spotify}/Applications/Spotify.app/Contents/MacOS/Spotify \
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
            (.identifier == "com.spotify.client")
            and (.team_name == "2FNC3A47ZF")
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
        "${spotify}/Applications/Spotify.app/Contents/Info.plist", "rb"
    ) as plist_file:
        plist = plistlib.load(plist_file)

    bundle_identifier = plist.get("CFBundleIdentifier")
    if bundle_identifier != "com.spotify.client":
        sys.exit(f"CFBundleIdentifier is {bundle_identifier!r}, expected 'com.spotify.client'")
    EOF

    mkdir "$out"
  ''

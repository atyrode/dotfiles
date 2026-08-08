{ lib, pkgs }:

pkgs.stdenvNoCC.mkDerivation {
  pname = "lichess";
  version = "1.0";

  dontUnpack = true;

  installPhase = ''
        runHook preInstall

        mkdir -p "$out/bin" "$out/share/applications"

        cat > "$out/bin/lichess" <<'EOF'
    #!/usr/bin/env sh
    url="https://lichess.org"

    if command -v open >/dev/null 2>&1; then
      exec open "$url"
    fi

    ${lib.optionalString pkgs.stdenv.isLinux ''
      if [ -x "${pkgs.xdg-utils}/bin/xdg-open" ]; then
        exec "${pkgs.xdg-utils}/bin/xdg-open" "$url"
      fi
    ''}

    if command -v xdg-open >/dev/null 2>&1; then
      exec xdg-open "$url"
    fi

    printf '%s\n' "$url"
    EOF
        chmod +x "$out/bin/lichess"

        cat > "$out/share/applications/lichess.desktop" <<EOF
    [Desktop Entry]
    Type=Application
    Name=Lichess
    Comment=Open lichess.org
    Exec=$out/bin/lichess
    Terminal=false
    Categories=Game;BoardGame;
    EOF
  ''
  + lib.optionalString pkgs.stdenv.isDarwin ''
        mkdir -p "$out/Applications/Lichess.app/Contents/MacOS"

        cat > "$out/Applications/Lichess.app/Contents/Info.plist" <<'EOF'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key>
      <string>Lichess</string>
      <key>CFBundleIdentifier</key>
      <string>org.lichess.webapp</string>
      <key>CFBundleName</key>
      <string>Lichess</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
      <key>LSApplicationCategoryType</key>
      <string>public.app-category.games</string>
    </dict>
    </plist>
    EOF

        cat > "$out/Applications/Lichess.app/Contents/MacOS/Lichess" <<'EOF'
    #!/bin/sh
    exec /usr/bin/open "https://lichess.org"
    EOF
        chmod +x "$out/Applications/Lichess.app/Contents/MacOS/Lichess"
  ''
  + ''
    runHook postInstall
  '';

  meta = {
    description = "Launcher for lichess.org";
    homepage = "https://lichess.org";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}

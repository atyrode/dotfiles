{
  fetchurl,
  jq,
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "bigpowers";
  version = "2.76.2";

  src = fetchurl {
    url = "https://registry.npmjs.org/bigpowers/-/bigpowers-${finalAttrs.version}.tgz";
    hash = "sha256-LExXq6d+K/FuYXheurlT3z8Il3nkidv3w3V83RsAvBE=";
  };

  nativeBuildInputs = [ jq ];

  postPatch = ''
    jq -e '
      .mcpServers."bigpowers-mcp".command == "node" and
      .mcpServers."bigpowers-mcp".args == ["bigpowers-mcp/build/index.js"]
    ' .mcp.json >/dev/null
    rm .mcp.json
  '';

  unpackPhase = ''
    runHook preUnpack

    mkdir source
    tar -xzf "$src" -C source --strip-components=1
    cd source

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    test "$(jq -r .version package.json)" = "${finalAttrs.version}"
    jq -e '.pi.skills == ["./.pi/skills"] and .pi.prompts == ["./.pi/prompts"]' package.json >/dev/null

    plugin_dir="$out/share/omp/plugins/bigpowers"
    mkdir -p "$plugin_dir"
    cp -R . "$plugin_dir"

    runHook postInstall
  '';

  meta = {
    description = "Software engineering skills and workflows for coding agents";
    homepage = "https://github.com/danielvm-git/bigpowers";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})

{ mono, runCommand }:

runCommand "tern-tunnel"
  {
    nativeBuildInputs = [ mono ];
  }
  ''
    mkdir -p "$out/bin"
    mcs -sdk:4.8 -langversion:5 -platform:anycpu -target:exe -optimize+ \
      -r:System.Core -r:System.Security -r:System.Management \
      -r:System.ServiceProcess -r:System.Web.Extensions \
      -out:"$out/bin/tern-tunnel.exe" \
      '${./TernTunnel.cs}' '${./TernProfileStore.cs}' '${./TernPlatform.cs}'
    chmod 0555 "$out/bin/tern-tunnel.exe"
  ''

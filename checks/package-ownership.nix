{ inventory, pkgs }:

let
  manifest = pkgs.writeText "atyrode-inventory.json" (builtins.toJSON inventory);
in
builtins.deepSeq inventory (pkgs.runCommand "check-evaluated-inventory-${inventory.identity.system}"
  { nativeBuildInputs = [ pkgs.jq ]; }
  ''
    jq -e '
      .schemaVersion == 1
      and (.identity.revision | type == "string" and length > 0)
      and (.identity.system | type == "string" and length > 0)
      and (.identity.platform == "linux" or .identity.platform == "darwin")
      and .authority.closureIncluded == false
      and .authority.mutableStateIncluded == false
      and (.capabilities | length > 0)
      and all(.capabilities[];
        (.name | type == "string" and length > 0)
        and (.title | type == "string" and length > 0)
        and (.purpose | type == "string" and length > 0)
        and (.consumer | type == "string" and length > 0)
        and (.platforms | type == "array" and length > 0)
        and (.deliverables | type == "array")
        and all(.deliverables[];
          (.kind == "package" or .kind == "application")
          and (.name | type == "string" and length > 0)
          and (.version | type == "string" and length > 0)
          and (.description | type == "string" and length > 0)
          and (.delivery | type == "string" and length > 0)
          and (.source | type == "string" and length > 0)
          and (.system == $system)
          and (.platform == $platform)))
      and .capabilities.server.marker
      and (.capabilities.server.deliverables | length == 0)
      and all(.hosts[];
        (.id | type == "string" and length > 0)
        and (.system == $system)
        and (.platform == $platform)
        and (.capabilities | type == "array" and length > 0)
        and (.deliverables | type == "array"))
      and ([.capabilities[].deliverables[].name] | length == (unique | length))
      and (if $platform == "darwin"
        then ([.capabilities.desktop.deliverables[] | select(.kind == "application")] | length > 0)
        else ([.capabilities[].deliverables[] | select(.kind == "application")] | length == 0)
      end)
    ' --arg system '${inventory.identity.system}' --arg platform '${inventory.identity.platform}' \
      ${manifest} >/dev/null
    mkdir "$out"
  '')

# Trusted declarative argv, not shell source. Keep shell quoting separate from
# authorized_keys option quoting: sshd decodes the latter before invoking the
# account's shell with the forced command.
{ lib }:
let
  fields = line: lib.filter builtins.isString (builtins.split "[[:blank:]]+" line);
  token = value: builtins.match "[[:graph:]]+" value != null;
  identifier = value: builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" value != null;
  parseLine =
    line:
    let
      argv = lib.filter (value: value != "") (fields line);
      count = builtins.length argv;
      at = builtins.elemAt argv;
      valid =
        count >= 5
        && lib.all token argv
        && identifier (at 0)
        && identifier (at 1)
        && at 2 == "ssh-ed25519"
        && builtins.match "[A-Za-z0-9+/]+={0,2}" (at 3) != null
        && lib.hasPrefix "/" (at 4)
        && at 4 != "/";
    in
    assert lib.assertMsg valid
      "deploy-keys requires NAME HOST ssh-ed25519 BASE64-KEY /ABSOLUTE-COMMAND [LITERAL-ARG...]";
    {
      name = at 0;
      hostId = at 1;
      keytype = at 2;
      key = at 3;
      command = lib.drop 4 argv;
    };
  parse =
    text:
    let
      lines = lib.filter (line: builtins.match "[[:blank:]]*(#.*)?" line == null) (
        lib.splitString "\n" text
      );
      entries = map parseLine lines;
      names = map (entry: entry.name) entries;
    in
    assert lib.assertMsg (builtins.length names == builtins.length (lib.unique names))
      "deploy-keys names must be unique";
    entries;
  render =
    entry:
    let
      # OpenSSH opt_dequote unescapes only \"; backslashes otherwise survive.
      command = lib.replaceStrings [ "\"" ] [ "\\\"" ] (lib.escapeShellArgs entry.command);
    in
    ''command="${command}",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc ${entry.keytype} ${entry.key} ${entry.name}'';
in
{
  inherit parse;
  forHost = hostId: text: map render (lib.filter (entry: entry.hostId == hostId) (parse text));
}

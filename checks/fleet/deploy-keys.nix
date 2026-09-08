{ lib, pkgs }:
let
  registry = import ../../modules/home/ssh/deploy-keys.nix { inherit lib; };
  text = builtins.readFile ../../modules/home/ssh/deploy-keys;
  receiver = "/run/current-system/sw/bin/manifold-preview-receiver";
  fixture = "fixture dev-01 ssh-ed25519 Zml4dHVyZQ==";
  rejected =
    record:
    !(builtins.tryEval (builtins.deepSeq (registry.forHost "dev-01" record) true)).success;
  malformed = [
    "fixture"
    "${fixture}"
    "${fixture} relative-command deploy"
    "${fixture} /"
    "fixture dev-01 ssh-ed25519-extra Zml4dHVyZQ== /command"
    "fixture dev-01 ssh-ed25519 invalid! /command"
    "bad,name dev-01 ssh-ed25519 Zml4dHVyZQ== /command"
    "${fixture} /command bad\rargument"
    "${fixture} /command\nunknown-extra-record"
    "${fixture} /command\n${fixture} /other"
    # Invalid rows for another host must not silently disappear before validation.
    "fixture other-host ssh-ed25519 Zml4dHVyZQ== relative-command"
  ];
  attackArgs = [
    "--unknown-extra"
    ";touch"
    "escaped-command"
    "$(touch)"
    "`touch`"
    "a'b"
    "a\"b"
    "a\\b"
    "a\\\"b"
    "*,no-pty"
  ];
  fixtureCommand = [ "${pkgs.coreutils}/bin/printf" "%s\\0" ] ++ attackArgs;
  fixtureLine = builtins.head (
    registry.forHost "dev-01" "${fixture} ${lib.concatStringsSep " " fixtureCommand}"
  );
  entries = registry.parse text;
  commands = lib.listToAttrs (map (entry: lib.nameValuePair entry.name entry.command) entries);
  data = pkgs.writeText "deploy-key-rendering.json" (
    builtins.toJSON {
      lines = registry.forHost "dev-01" text;
      inherit fixtureLine attackArgs receiver;
    }
  );
in
assert lib.assertMsg (lib.all rejected malformed) "malformed deploy-key records must fail closed";
assert lib.assertMsg (registry.forHost "other-host" text == [ ])
  "deploy keys must not reach unregistered hosts";
assert lib.assertMsg (
  commands == {
    manifold-deploy = [ receiver "deploy" ];
    plugins-deploy = [
      receiver
      "plugin-delivery"
      "in-realm"
      "https://github.com/atyrode/code/releases/"
      "https://github.com/atyrode/babel/releases/"
    ];
  }
) "existing deploy keys must retain exactly their separate deployment and own-plugin authorities";
pkgs.runCommand "check-deploy-keys"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 - ${data} ${pkgs.runtimeShell} ${pkgs.zsh}/bin/zsh <<'PY'
    import json
    import shlex
    import subprocess
    import sys

    data = json.load(open(sys.argv[1]))
    restrictions = ',no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc'

    def decode(line):
        # OpenSSH misc.c opt_dequote: only backslash-double-quote is escaped.
        assert line.startswith('command="')
        index = len('command="')
        command = []
        while index < len(line) and line[index] != '"':
            if line[index:index + 2] == '\\"':
                index += 1
            command.append(line[index])
            index += 1
        assert index < len(line), 'unterminated forced command'
        assert line[index + 1:].startswith(restrictions + ' ssh-ed25519 ')
        return "".join(command)

    commands = {line.rsplit(' ', 1)[1]: shlex.split(decode(line)) for line in data['lines']}
    assert commands == {
        'manifold-deploy': [data['receiver'], 'deploy'],
        'plugins-deploy': [data['receiver'], 'plugin-delivery', 'in-realm',
                           'https://github.com/atyrode/code/releases/',
                           'https://github.com/atyrode/babel/releases/'],
    }
    command = decode(data['fixtureLine'])
    expected = b"".join(arg.encode() + b'\0' for arg in data['attackArgs'])
    # Exercise the actual host shell as well as the Nix build shell. Unknown
    # extra argv must survive literally, never be dropped or become shell code.
    for shell in sys.argv[2:]:
        result = subprocess.run([shell, '-c', command], check=True, capture_output=True)
        assert result.stdout == expected, (shell, result.stdout, expected)
    PY
    mkdir "$out"
  ''

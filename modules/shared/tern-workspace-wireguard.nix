{ pkgs, ... }:
{
  clan.core.vars.generators.tern-workspace-wireguard = {
    files.privatekey = {
      secret = true;
      mode = "0600";
    };
    files.publickey = {
      secret = false;
      deploy = false;
    };
    runtimeInputs = [ pkgs.wireguard-tools ];
    script = ''
      umask 077
      wg genkey > "$out/privatekey"
      wg pubkey < "$out/privatekey" > "$out/publickey"
    '';
  };
}

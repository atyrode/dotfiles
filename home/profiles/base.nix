{ lib, pkgs, ... }:

let
  # NixOS-WSL exposes the Windows NVIDIA driver through this fixed path rather
  # than the normal Linux driver closure. Keep ordinary btop behavior on every
  # other Linux host while enabling its already-compiled NVML support in WSL.
  #
  # writeShellScriptBin threads no meta argument, so the description that the
  # inventory demands of every repository-defined package is attached to the
  # finished wrapper.
  btopWithOptionalWslNvidia =
    lib.addMetaAttrs
      {
        description = "btop with optional NVIDIA GPU support on NixOS-WSL";
      }
      (
        pkgs.writeShellScriptBin "btop" ''
          if [[ -r /usr/lib/wsl/lib/libnvidia-ml.so.1 ]]; then
            export LD_LIBRARY_PATH="/usr/lib/wsl/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          fi
          exec ${lib.getExe pkgs.btop} "$@"
        ''
      );
  btopPackage = if pkgs.stdenv.hostPlatform.isLinux then btopWithOptionalWslNvidia else pkgs.btop;
in
{
  imports = [
    ../git.nix
    ../mise.nix
    ../ssh.nix
    ../zsh.nix
  ];

  # Home Manager uses this as a compatibility marker for stateful defaults.
  # Keep it fixed after first activation unless every skipped release note has
  # been reviewed explicitly.
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;

  home.packages =
    (with pkgs; [
      atyrode
      bat
      btopPackage
      curl
      dua
      fd
      file
      gnutar
      gzip
      jq
      less
      lsof
      nano
      ncurses
      ripgrep
      rsync
      tree
      unzip
      vim
      wget
      which
      xz
      zip
    ])
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
      pkgs.watch
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      (pkgs.buildEnv {
        name = "bind-tools";
        paths = [
          pkgs.bind.dnsutils
          pkgs.bind.host
        ];
        meta.description = "BIND DNS client tools: dig, delv, nslookup, nsupdate, and host";
      })
      pkgs.iproute2
      pkgs.netcat-openbsd
      pkgs.psmisc
      pkgs.strace
    ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.fzf = {
    enable = true;
    # fzf's generated zshrc hook restores shell options via eval, and
    # restoring the zle option fails ("can't change option: zle") in
    # interactive shells without a TTY — which is every agent eval shell.
    # The TTY-guarded replacement lives in home/zsh.nix. (#255)
    enableZshIntegration = false;
  };
  programs.zoxide.enable = true;
}

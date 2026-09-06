{
  config,
  lib,
  pkgs,
  ...
}:

let
  gitAuthMode = config.atyrode.gitAuthMode;
  useSshAuth = gitAuthMode == "ssh";
  identity = config.atyrode.gitIdentity;
  hasIdentity = identity.signingKey != null;
in
{
  options.atyrode.gitAuthMode = lib.mkOption {
    type = lib.types.enum [
      "ssh"
      "https-gh"
    ];
    default = "ssh";
    description = "Git transport authentication mode; commit signing remains SSH-backed in every mode.";
  };

  # The machine's Git keys, as paths to private keys activation placed. A clan
  # machine sets both from its git-identity generator (modules/shared/
  # git-identity.nix); a portable profile is not a fleet member and has none,
  # so it signs nothing rather than signing with a key nobody reviewed.
  options.atyrode.gitIdentity = {
    authKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Private SSH key that authenticates this machine to forges.";
    };
    signingKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Private SSH key that signs this machine's commits; its public half must be in allowed-signers.";
    };
  };

  config = {
    programs.git = {
      enable = true;

      settings = {
        user.name = "Alex TYRODE";
        user.email = "alex@tyrode.dev";

        # Authentication and commit signing are independent. SSH-first hosts use
        # push-only rewrites; external-auth runtimes keep HTTPS so the declared gh
        # credential helper can serve Git without an additional authentication key.
        # ssh-keygen -Y sign reads the private key file directly, so signing
        # needs no agent and no passphrase: the key is placed 0600 for this
        # account by activation, and the machine signs the moment it is up.
        gpg.format = "ssh";
        gpg.ssh.allowedSignersFile = "${config.xdg.configHome}/git/allowed_signers";
        core.hooksPath = "${config.xdg.configHome}/git/hooks";
        # Useful defaults
        init.defaultBranch = "main";
        pull.rebase = false;
        push.autoSetupRemote = true;
        fetch.prune = true;
        commit.gpgsign = hasIdentity;

        includeIf."gitdir/i:**/gitlab.alouette.dev/**".path = "~/.gitconfigs/.alouette.config";

        # Better diff/merge tools
        diff.colorMoved = "default";
        merge.conflictstyle = "diff3";

        # Git aliases
        alias.st = "status";
        alias.co = "checkout";
        alias.br = "branch";
        alias.ci = "commit";
        alias.unstage = "reset HEAD --";
        alias.last = "log -1 HEAD";
        alias.visual = "!gitk";
      }
      // lib.optionalAttrs hasIdentity { user.signingKey = identity.signingKey; }
      # Git alone reaches the forges with the placed auth key, and with that key
      # only: IdentitiesOnly keeps ssh from offering every key an agent holds,
      # which is how a forge ends up authenticating a machine as someone else.
      # Scoped to git rather than written into ~/.ssh/config, so the account's
      # own ssh configuration -- other hosts, other keys -- stays its own.
      // lib.optionalAttrs (useSshAuth && identity.authKey != null) {
        core.sshCommand = "${lib.getExe pkgs.openssh} -i ${identity.authKey} -o IdentitiesOnly=yes";
      }
      // lib.optionalAttrs useSshAuth {
        url."git@github.com:".pushInsteadOf = "https://github.com/";
        url."git@gitlab.com:".pushInsteadOf = "https://gitlab.com/";
      };
    };

    # Neither signing nor forge authentication needs an agent any more: both
    # read the placed key file. The Linux user agent stays for ordinary
    # interactive ssh, where a passphrase-protected key an operator adds by
    # hand should survive the shell that added it. macOS keeps its own.
    services.ssh-agent.enable = pkgs.stdenv.hostPlatform.isLinux;

    programs.gh = {
      enable = true;
      settings.git_protocol = if useSshAuth then "ssh" else "https";

      # Keep gh's Git helper declarative so `gh auth setup-git` never needs to
      # rewrite the managed Git config. doctor git audits gh's token store
      # separately and rejects the plaintext hosts.yml fallback.
      gitCredentialHelper.enable = true;
    };

    xdg.configFile = {
      "git/allowed_signers".source = ./allowed-signers;
      "git/hooks/pre-push" = {
        source = ./pre-push;
        executable = true;
      };
      # The scanner is a store path inside the hook, not a package on PATH, so
      # a commit from an editor or a GUI client is scanned exactly like one
      # from a shell.
      "git/hooks/pre-commit" = {
        text = builtins.replaceStrings [ "@gitleaks@" ] [ (lib.getExe pkgs.gitleaks) ] (
          builtins.readFile ./pre-commit
        );
        executable = true;
      };
    };
  };
}

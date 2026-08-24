{ config, lib, ... }:

let
  gitAuthMode = config.atyrode.gitAuthMode;
  useSshAuth = gitAuthMode == "ssh";
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

  config = {
    programs.git = {
      enable = true;

      settings = {
        user.name = "Alex TYRODE";
        user.email = "alex@tyrode.dev";
        user.signingKey = "${config.home.homeDirectory}/.ssh/id_ed25519_git_signing.pub";

        # Authentication and commit signing are independent. SSH-first hosts use
        # push-only rewrites; external-auth runtimes keep HTTPS so the declared gh
        # credential helper can serve Git without an additional authentication key.
        gpg.format = "ssh";
        gpg.ssh.allowedSignersFile = "${config.xdg.configHome}/git/allowed_signers";
        core.hooksPath = "${config.xdg.configHome}/git/hooks";
        # Useful defaults
        init.defaultBranch = "main";
        pull.rebase = false;
        push.autoSetupRemote = true;
        fetch.prune = true;
        commit.gpgsign = true;

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
      // lib.optionalAttrs useSshAuth {
        url."git@github.com:".pushInsteadOf = "https://github.com/";
        url."git@gitlab.com:".pushInsteadOf = "https://gitlab.com/";
      };
    };

    programs.gh = {
      enable = true;
      settings.git_protocol = if useSshAuth then "ssh" else "https";

      # Keep gh's Git helper declarative so `gh auth setup-git` never needs to
      # rewrite the managed Git config. doctor git audits gh's token store
      # separately and rejects the plaintext hosts.yml fallback.
      gitCredentialHelper.enable = true;
    };

    xdg.configFile = {
      "git/allowed_signers".source = ./git-allowed-signers;
      "git/hooks/pre-push" = {
        source = ./git-pre-push;
        executable = true;
      };
    };
  };
}

{ config, ... }:

{
  programs.git = {
    enable = true;

    settings = {
      user.name = "Alex TYRODE";
      user.email = "alex@tyrode.dev";
      user.signingKey = "${config.home.homeDirectory}/.ssh/id_ed25519_git_signing.pub";

      # Never persist Git credentials in plaintext; use SSH remotes/agents or
      # a platform credential manager instead.
      gpg.format = "ssh";
      gpg.ssh.allowedSignersFile = "${config.xdg.configHome}/git/allowed_signers";

      # `insteadOf` would also rewrite anonymous HTTPS fetches (including Nix
      # flake inputs) on hosts that may not have a key loaded. Keep fetches
      # unchanged: gh emits SSH clone URLs, while these push-only rewrites make
      # GitHub and GitLab authentication use SSH for manually added HTTPS remotes.
      url."git@github.com:".pushInsteadOf = "https://github.com/";
      url."git@gitlab.com:".pushInsteadOf = "https://gitlab.com/";
      # Useful defaults
      init.defaultBranch = "main";
      pull.rebase = false;
      push.autoSetupRemote = true;
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
    };
  };

  programs.gh = {
    enable = true;
    settings.git_protocol = "ssh";

    # Keep gh's Git helper declarative so `gh auth setup-git` never needs to
    # rewrite the managed Git config. doctor git audits gh's token store
    # separately and rejects the plaintext hosts.yml fallback.
    gitCredentialHelper.enable = true;
  };

  xdg.configFile."git/allowed_signers".source = ./git-allowed-signers;
}

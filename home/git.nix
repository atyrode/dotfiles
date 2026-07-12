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
      gpg.ssh.allowedSignersFile = "${config.home.homeDirectory}/.config/git/allowed_signers";
      
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
}

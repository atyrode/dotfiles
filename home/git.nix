{
  programs.git = {
    enable = true;
    
    settings = {
      user.name = "Alex TYRODE";
      user.email = "alex@tyrode.dev";
      user.signingKey = "/home/alex/.ssh/id_ed25519_git_signing.pub";
      
      credential.helper = "store";
      gpg.format = "ssh";
      gpg.ssh.allowedSignersFile = "/home/alex/.config/git/allowed_signers";
      
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

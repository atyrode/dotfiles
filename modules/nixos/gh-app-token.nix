# The GitHub identity of the operator's agents on dev-01: a GitHub App owned by
# the tyrode-dev organisation and installed on tyrode-dev/myParcelle alone, so
# the agents' `gh` and `git` calls spend the App installation's rate limit and
# are attributed to the App's bot, never to the operator's account.
#
# Which App is one fact, fleet/github-app.json, and `enabled` stays false until
# the operator has created it (local://gh-app-guide.md in the planning
# session; the steps are in docs/agent-tools.md#github-app-identity-for-agents).
# While it is false this module defines nothing: no generator, so
# `clan vars generate dev-01` does not prompt for a key that does not exist yet.
#
#   key      the App's private key, a per-machine prompted clan var placed
#            0400 for `gh-app`, a system account no agent runs as. The agents
#            run as the operator's account and never read it; the operator
#            account is root-equivalent (passwordless sudo), so this is a
#            guard against accident and a reduced blast radius, not a wall.
#   minter   `gh-app-token.service`, as `gh-app`, signs a ten-minute JWT with
#            the key and exchanges it for an installation token limited to the
#            listed repositories (one hour). A timer renews it every thirty
#            minutes. The token and its expiry land in /run/gh-app-token, group
#            readable by the operator account, never in the Nix store or logs.
#   gh       a `gh` shim that, in a tyrode-dev clone under ~/lanes (the place
#            the git include below applies) or wherever GH_IDENTITY=app, reads
#            the token file on every call and runs the real gh with it as
#            GH_TOKEN, host and configuration directory pinned so no stored
#            login exists to fall back to. Reading per call means a session
#            never holds a stale token and nothing needs refreshing per
#            session. It fails closed: no token, no fallback to the operator's
#            own `gh auth` credentials. GH_IDENTITY must be exactly `app` or
#            `operator`; GH_IDENTITY=operator opts out.
#   git      an include after the main configuration (programs.git.includes,
#            so its values win over the operator's [user]), active only in
#            clones under ~/lanes whose remote is a tyrode-dev repository:
#            the bot's name and noreply address, no local signing (the
#            operator's signing key says a commit is the operator's), HTTPS in
#            place of the operator's SSH key for fetch and push, and a
#            credential helper that serves the same token file. Other clones
#            there (dotfiles) keep the operator's identity and key. The include
#            also sets gh-app.lane, which the shim reads, so both tools agree
#            on where the App identity applies.
#   scope    the token request lists its permissions explicitly
#            (fleet/github-app.json): a permission later added to the App in
#            GitHub does not reach the agents until a reviewed change lists it.
#            OPTION `workflowsWrite` (recommended on): adds `workflows: write`
#            so agents can push edits to .github/workflows (CI PRs). Set it
#            false, and leave Workflows unticked on the App, to refuse that.
#   readers  every process running as the operator account, `ompu` sandboxes
#            included, can read the token file, as it could already read the
#            operator's SSH key and gh login; the sandbox is environment-only.
#
# The Anthropic/OpenAI broker (omp-auth-broker) stays out of this: it vaults
# model-provider credentials, has no GitHub App support and is not ours to extend.
{
  config,
  lib,
  pkgs,
  host,
  ...
}:
let
  app = lib.importJSON ../../fleet/github-app.json;
  inherit (host) username homeDirectory;

  lanes = "${homeDirectory}/lanes";
  permissions = app.permissions // lib.optionalAttrs app.workflowsWrite { workflows = "write"; };
  service = "gh-app";
  runtimeName = "gh-app-token";
  tokenFile = "/run/${runtimeName}/token";

  # Stated from sops-nix's fixed layout and asserted against clan's answer once
  # there is one, for the reason cloudflare-dns.nix gives.
  placed = "/run/secrets/vars/gh-app/private-key";
  reported = config.clan.core.vars.generators.gh-app.files."private-key".path;

  botName = "${app.slug}[bot]";
  botEmail = "${toString app.botUserId}+${app.slug}[bot]@users.noreply.github.com";

  minter = pkgs.writeShellApplication {
    name = "gh-app-token-mint";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.openssl
    ];
    text = ''
      umask 027
      out=/run/${runtimeName}

      b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

      now=$(date +%s)
      header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
      payload=$(jq -nc --argjson iat "$((now - 60))" --argjson exp "$((now + 540))" \
        --arg iss ${lib.escapeShellArg (toString app.appId)} '{iat: $iat, exp: $exp, iss: $iss}' | b64url)
      signature=$(printf '%s.%s' "$header" "$payload" |
        openssl dgst -sha256 -sign ${placed} | b64url)

      body=$(jq -nc --argjson repositories ${lib.escapeShellArg (builtins.toJSON app.repositories)} \
        --argjson permissions ${lib.escapeShellArg (builtins.toJSON permissions)} \
        '{repositories: $repositories, permissions: $permissions}')

      # The JWT travels on curl's stdin, never its argv, and nothing below
      # prints a response body: a refusal is reported by status alone.
      status=$(printf 'header = "Authorization: Bearer %s"\n' "$header.$payload.$signature" |
        curl --silent --max-time 30 --config - \
          --header 'Accept: application/vnd.github+json' \
          --header 'X-GitHub-Api-Version: 2022-11-28' \
          --data "$body" --output "$out/response.json" --write-out '%{http_code}' \
          https://api.github.com/app/installations/${toString app.installationId}/access_tokens) || status=000
      if [[ $status != 201 ]]; then
        rm -f "$out/response.json"
        echo "gh-app-token: GitHub answered $status to the installation token request" >&2
        exit 1
      fi

      token=$(jq -er '.token' "$out/response.json")
      expires=$(jq -er '.expires_at' "$out/response.json")
      rm -f "$out/response.json"
      [[ $token =~ ^ghs_[A-Za-z0-9_]+$ ]] ||
        { echo "gh-app-token: the answer carried no installation token" >&2; exit 1; }

      printf '%s\n' "$token" >"$out/token.new"
      printf '%s\n' "$expires" >"$out/expires-at.new"
      mv -f "$out/token.new" "$out/token"
      mv -f "$out/expires-at.new" "$out/expires-at"
      echo "gh-app-token: installation token renewed, expires $expires"
    '';
  };

  # `gh` for the agents. It replaces the one on PATH (hiPrio below), so every
  # tool that shells out to `gh` -- OMP's github tool included -- goes through it.
  ghShim = pkgs.writeShellApplication {
    name = "gh";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
    ];
    text = ''
      mode=''${GH_IDENTITY-}
      case "$mode" in
        app | operator) ;;
        "")
          # Default: the App identity applies exactly where the lane git
          # include does -- a tyrode-dev clone whose real path is in the lanes
          # directory -- so gh and git never disagree about who is acting.
          mode=operator
          lanes=$(realpath -m ${lanes})
          here=$(pwd -P)
          if [[ $here == "$lanes"/* ]] &&
            [[ $(git config --type=bool --get gh-app.lane 2>/dev/null) == true ]]; then
            mode=app
          fi
          ;;
        *)
          echo "gh: GH_IDENTITY must be exactly 'app' or 'operator'" >&2
          exit 1
          ;;
      esac

      if [[ $mode == app ]]; then
        token=""
        [[ ! -r ${tokenFile} ]] || token=$(<${tokenFile})
        if [[ ! $token =~ ^ghs_[A-Za-z0-9_]+$ ]]; then
          echo "gh: the agents' GitHub App token is missing or malformed (${tokenFile}); refusing to fall back to the operator's credentials. GH_IDENTITY=operator overrides." >&2
          exit 1
        fi
        if (( $(date +%s) - $(stat -c %Y ${tokenFile}) > 3900 )); then
          echo "gh: the App token is older than an hour; gh-app-token.service is not renewing it" >&2
        fi
        # An empty configuration directory leaves gh no stored login, host or
        # protocol preference of the operator's to use instead of the token.
        config_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/gh-app/gh-config"
        (umask 077 && mkdir -p "$config_dir")
        export GH_TOKEN=$token GH_CONFIG_DIR=$config_dir
        unset GH_HOST GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
      fi

      exec ${lib.getExe pkgs.gh} "$@"
    '';
  };

  credentialHelper = pkgs.writeShellApplication {
    name = "gh-app-git-credential";
    text = ''
      [[ ''${1:-} == get ]] || exit 0
      host=""
      protocol=""
      while IFS='=' read -r key value; do
        [[ -n $key ]] || break
        case "$key" in
          host) host=$value ;;
          protocol) protocol=$value ;;
          *) ;;
        esac
      done
      [[ $host == github.com && $protocol == https && -r ${tokenFile} ]] || exit 0
      printf 'username=x-access-token\npassword=%s\n' "$(<${tokenFile})"
    '';
  };

  # The identity itself, read only through the nested conditions below.
  laneIdentityConfig = pkgs.writeText "gh-app-identity.gitconfig" ''
    [gh-app]
    	lane = true
    [user]
    	name = ${botName}
    	email = ${botEmail}
    [commit]
    	gpgsign = false
    [url "https://github.com/"]
    	insteadOf = git@github.com:
    	insteadOf = ssh://git@github.com/
    # The operator's configuration rewrites every https push to SSH with the
    # operator's key. A longer identical prefix wins over that rewrite.
    [url "https://github.com/${app.owner}/"]
    	pushInsteadOf = https://github.com/${app.owner}/
    [credential "https://github.com"]
    	helper =
    	helper = ${lib.getExe credentialHelper}
  '';

  # Included for any clone under ~/lanes; applies the identity only when a
  # remote is a tyrode-dev repository, in either URL form.
  laneGitConfig = pkgs.writeText "gh-app-lanes.gitconfig" ''
    [includeIf "hasconfig:remote.*.url:https://github.com/${app.owner}/**"]
    	path = ${laneIdentityConfig}
    [includeIf "hasconfig:remote.*.url:git@github.com:${app.owner}/**"]
    	path = ${laneIdentityConfig}
  '';
in
{
  config = lib.mkIf app.enabled {
    assertions = [
      {
        assertion = app.schemaVersion == 1;
        message = "fleet/github-app.json has an unsupported schemaVersion";
      }
      {
        assertion =
          app.slug != ""
          && app.appId > 0
          && app.installationId > 0
          && app.botUserId > 0
          && app.permissions != { };
        message = "fleet/github-app.json is enabled but names no slug, appId, installationId, botUserId and permissions";
      }
      {
        assertion = reported == "/no-such-path" || reported == placed;
        message = "gh-app-token expects ${placed}, but sops-nix places it at ${reported}";
      }
    ];

    clan.core.vars.generators.gh-app = {
      prompts."private-key" = {
        description = "the private key (.pem) of the ${app.owner} GitHub App ${app.slug}, pasted whole";
        type = "multiline-hidden";
      };

      files."private-key" = {
        secret = true;
        owner = service;
        group = service;
        mode = "0400";
      };

      runtimeInputs = [
        pkgs.coreutils
        pkgs.openssl
      ];

      # GitHub issues PKCS#1 RSA keys. Anything else -- a certificate, a
      # client secret, an empty paste -- is refused without being quoted.
      script = ''
        tr -d '\r' <"$prompts/private-key" >"$out/private-key"
        head -n1 "$out/private-key" | grep -qx -- '-----BEGIN RSA PRIVATE KEY-----' &&
          openssl rsa -in "$out/private-key" -check -noout >/dev/null 2>&1 ||
          { echo "gh-app: private-key is not an RSA private key" >&2; exit 1; }
      '';
    };

    users.groups.${service} = { };
    users.users.${service} = {
      isSystemUser = true;
      group = service;
      description = "GitHub App installation token minter";
    };
    # The group reads the token directory; the key itself is 0400 for the
    # account alone.
    users.users.${username}.extraGroups = [ service ];

    systemd.services.gh-app-token = {
      description = "Renew the agents' GitHub App installation token";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = service;
        Group = service;
        ExecStart = lib.getExe minter;
        RuntimeDirectory = runtimeName;
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = "yes";
        TimeoutStartSec = 60;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        UMask = "0027";
      };
    };

    systemd.timers.gh-app-token = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5s";
        OnBootSec = "20s";
        OnUnitActiveSec = "30min";
        AccuracySec = "10s";
      };
    };

    home-manager.users.${username} = _: {
      home.packages = [ (lib.hiPrio ghShim) ];
      # `includes`, not `settings.includeIf`: Home Manager writes includes after
      # the main configuration, so the bot's [user] overrides the operator's.
      programs.git.includes = [
        {
          condition = "gitdir:${lanes}/";
          path = laneGitConfig;
        }
      ];
    };
  };
}

# One private Tern workspace

Open **`https://tern.tyrode.dev`** in a paired browser, or connect from the first window of an enrolled Mac or Windows Tern desktop app using **`tern-workspace@tern.tyrode.dev:944`**. Both reach the same daemon on `dev-01` over the private WireGuard tunnel. Closing a tab or shutting down a client does not stop a server-side shell. Native access uses QUIC, not SSH, the public web edge, or a relay.

`tern-workspace-daemon` owns the panes. The `tern-workspace-web` (HTTPS via private Caddy) and `tern-workspace-native` (QUIC) frontends attach to its existing Unix socket as `tern-workspace`. Restarting a frontend alone leaves the daemon and running pane processes alone. The daemon's socket lives under the dedicated workspace home because Tern saves its workspace state beside that socket. On a clean daemon restart, Tern restores saved sessions, tab and pane layouts, working directories, and scrollback. Restarting the daemon or rebooting the server still ends running processes: a restored pane starts a new shell, not the old process or its running command. The workspace starts empty on first provision, not each time a device connects.

When the last client leaves an empty workspace, Tern can shut down cleanly. Systemd brings back the daemon and its frontends without opening a pane or connecting to the daemon as a startup probe. The next client attaches to the saved workspace; it may need to reconnect if it arrives during that restart.

The workspace runs as `tern-workspace`, not the SSH administrator. Its writable home is `/var/lib/tern-workspace`, not `/home/alex`. Clone projects and authorize development tools in that account through their normal login flows; do not copy another account's sessions. Loss of this disk is not a reconnect: protect the workspace home with an appropriately private backup if recovery is required. [Stencil Tern](https://stencil.so/tern#everywhere) is a closed beta, not FOSS. WireGuard and Caddy are self-hosted; Tern 0.9.29's default web client fetches a versioned, integrity-checked WebAssembly asset from `build.stencil.so`. This setup is not a promise of offline operation or zero vendor contact.

## First provision

1. **Name and certificate.** Create a DNS-only A record for `tern.tyrode.dev` using `serverAddress` from the [dev-01 overlay addresses](../fleet/machines/dev-01/tern-network.json). From the checkout root, print the value with `jq -r '.serverAddress' fleet/machines/dev-01/tern-network.json`. No proxy, public-address A, or AAAA. `dev-01.tyrode.dev` must still resolve publicly: it is the WireGuard endpoint, not the private website. Issue a dedicated Cloudflare API token with Zone:Read and DNS:Edit restricted to the DNS-01 validation zone. To avoid granting write access to the primary zone, delegate `_acme-challenge.tern.tyrode.dev` by CNAME into a separately managed zone and scope the token there. Where the server has a stable egress IP, restrict the token to it. In an authorized writable checkout, enter the token only at the hidden prompt:

   ```sh
   CLAN_NO_COMMIT=1 nix shell --inputs-from . nixpkgs#age-plugin-se -c \
     clan vars generate dev-01 --generator tern-workspace-dns --flake "$PWD"
   ```

   Publish the Clan-encrypted result through the usual review path, not the token. The private proxy will not serve the placeholder self-signed certificate. ACME renewals neither expose port 80 nor restart the Tern daemon. If a resolver filters private addresses in public DNS, add an exception for **this name** on the resolver you control or return that same A record in private DNS. Do not disable DNS-rebinding protection globally.

2. **Server.** Install the licensed Linux `tern` **0.9.29** from Stencil in the primary user's normal installer location (`~/.local/bin/tern`) if not already present. The system service checks the approved digest before publishing an executable into `/var/lib/tern-workspace-bin`; neither the executable nor Tern account state is redistributed in Git or Nix. An absent or different build fails closed. Review `atyrode apply dev-01 --preview-json` and apply the published revision through the normal [session-preserving activation](atyrode.md#the-mutation-boundary). Do not override a blocked disruption. The workspace's WireGuard and Mac peer keys are already enrolled through Clan, separate from fleet administration.

   `wireguard-wg-tern.service` owns the `wg-tern` interface and its per-peer routes. The public uplink stays under networkd; `51837/udp` carries encrypted WireGuard traffic. Workspace HTTPS is overlay-only; direct QUIC on `944/udp` is also overlay-only and limited to peers enrolled for native access. The tunnel starts after the ingress firewall rules and only with a nonempty server key. Stopping the tunnel stops the private Caddy and native listeners before removing the interface; stopping the ingress unit also stops the tunnel before removing its rules.

3. **Clients.** The [public peer inventory](../fleet/tern-workspace.nix) pairs each device's public key with its address from the dev-01 overlay addresses. A `null` peer key admits **no** device at that address. Never paste a private key or a WireGuard configuration into Git, chat or a debugging command.

   | Device | First setup | Afterwards |
   |---|---|---|
   | Mac (`macbook`) | Run `atyrode apply macbook`. nix-darwin configures WireGuard and its native launchd job from the machine's Clan key; no separate GUI profile or On-Demand switch. | The tunnel starts at boot. Use a browser or enroll Tern desktop as described below. |
   | Windows (`wsl`) | Open **Windows Terminal as Administrator**, enter the managed WSL distro (`wsl -d atyrode-nixos`), and run `atyrode apply wsl`. Its Windows phase installs WireGuard and configures the native `atyrode-tern` tunnel, not a VPN inside WSL. Enroll the **public** key the phase reports as `peers.windows.publicKey`, publish and apply on `dev-01`. Running `atyrode windows plan` or `atyrode windows apply` in the managed distro inspects or reruns just that phase. WSL `sudo` alone does not elevate Windows. | Windows Service Control Manager starts the tunnel without WSL, a terminal, a tray window or another UAC approval. Leave unrelated profiles untouched; an automatically chosen local listen port is normal. |
   | iPhone | In the WireGuard app, create a tunnel and **generate a new key on the phone**. Enroll only its public key as `peers.iphone.publicKey`, publish and apply on `dev-01`. Use the interface address and peer Allowed IPs printed below. For its one peer use the [server public key](../vars/per-machine/dev-01/tern-workspace-wireguard/publickey/value), endpoint `dev-01.tyrode.dev:51837`, and keepalive `25`. Leave DNS and listen port unset. Approve the iOS VPN permission and enable On-Demand for Wi-Fi and cellular. | iOS brings up the split tunnel. Open the same URL in a WebGPU-capable browser. There is no `atyrode apply` on iOS. |

   On Windows, reserve the native adapter name `atyrode-tern` and the workspace host route (`serverAddress/32`) for this tunnel. The Windows Plan and Apply phases refuse a conflicting native adapter or route during provisioning. At boot, Windows Service Control Manager starts WireGuard itself, not a background conflict monitor. Do not assign the same adapter name or host route to another VPN later.

   From the checkout root, print the iPhone WireGuard fields:

   ```sh
   jq -r '"Interface address: \(.clients.iphone)/32", "Peer Allowed IPs: \(.serverAddress)/32"' \
     fleet/machines/dev-01/tern-network.json
   ```

4. **Pair each browser once.** WireGuard admits a device to the network; Tern separately authorizes a browser to control the workspace. Retrieve `/var/lib/tern-workspace/.config/tern/web-token` on `dev-01` **only in a private administrator terminal**, then use `https://tern.tyrode.dev/?token=…` for that browser's first successful connection. Treat that link like a shell password: no shared logs, tickets, screenshots or public bookmarks. Bookmark only the bare URL. Tern 0.9.29 remembers it in that browser's site storage; clearing site data, changing browser profiles or using private browsing can require pairing again. Never use the browser token for native access, as a proxy credential, or in DNS.

## Enroll a native desktop

1. On macOS or **native Windows (not WSL)**, enroll the two fields `ssh-ed25519 <public-key>` from the desktop user's `~/.ssh/id_ed25519.pub` (`%USERPROFILE%\.ssh\id_ed25519.pub` on Windows) as that device's `nativePublicKey` in the [peer inventory](../fleet/tern-workspace.nix). Leave off any trailing comment. Publish and apply the reviewed change on `dev-01`. The native listener requires at least one peer with both keys enrolled. The native key does not grant SSH access; its private half stays on the desktop.
2. Obtain the native host's public `SHA256:` fingerprint independently, from a trusted administrator login shell on `dev-01`. After activation, read the existing identity using the service account and its config and loader environment:

   ```sh
   state=/var/lib/tern-workspace-native
   systemctl is-active --quiet tern-workspace-native.service &&
     sudo -u tern-workspace test -s "$state/host_key" &&
     sudo -u tern-workspace env HOME="$state" TERN_CONFIG_DIR="$state" \
       XDG_RUNTIME_DIR=/run/tern-workspace-native \
       NIX_LD="$NIX_LD" NIX_LD_LIBRARY_PATH="$NIX_LD_LIBRARY_PATH" \
       /var/lib/tern-workspace-bin/tern remote host-key --state-dir "$state"
   ```

   The state directory is owned by `tern-workspace` with mode `0700`, separate from the daemon's config, browser token, and administrator's per-user Tern service. Share only the fingerprint; never read out or copy `host_key`.

3. With WireGuard up, in Tern's **first** desktop window choose **Add remote host** and enter `tern-workspace@tern.tyrode.dev:944`. Do **not** choose setup over SSH: this listener is already managed by systemd. Compare the prompt with the fingerprint obtained on the server before trusting that hostname and port. Stop if it differs.

The browser workspace uses Tern's first-window key (`""`). Tern matches the local window key on the host; a later desktop window can show an empty or different session set on the very same daemon. Tern does not let the client choose the remote window key ([upstream #204](https://github.com/stencil-hq/tern-sdk/issues/204)). An empty window is not proof of attachment to the shared pane.

## Verify and operate

- From a paired device, start a long-running command in a pane. Open the bare URL on a second paired device, confirm the **same pane and changing output**, and type into the same shell. Reboot a client; the URL should open without starting WireGuard manually. For the phone, try both cellular and Wi-Fi. This tests the workspace rather than just a status page or TLS certificate.
- A local Tern 0.9.29 loopback experiment used real QUIC: an approved key attached to the existing daemon's first-window pane, and an unlisted key was rejected. This proves attachment, not a live `dev-01` or Mac/Windows desktop rollout. After activation, verify on each enrolled desktop that the first window shows the browser's **same running pane** and that input from either client appears in the other. With WireGuard disconnected, direct native access must fail.
- On a disposable empty workspace, leave the unpaired page open for at least 30 seconds, then pair and open a pane. Close the last pane and disconnect; after the idle restart, reconnect from the same browser and confirm you can open a pane without pairing again.
- On `dev-01`, `systemctl is-active wireguard-wg-tern tern-workspace-daemon tern-workspace-web tern-workspace-caddy tern-workspace-native` and `sudo wg show wg-tern latest-handshakes` separate application, ingress and peer failures. An enrolled client routes only the server's overlay address (`serverAddress/32`); the server admits HTTPS and, for native-enrolled peers, QUIC, not SSH or peer-to-peer traffic. Off-VPN clients should not reach either endpoint. Private DNS resolution alone proves neither a connection nor authorization.
- To revoke only native access, set that peer's `nativePublicKey` to `null`. To revoke all access, set both `nativePublicKey` and `publicKey` to `null`. Publish and apply on `dev-01`. For the Mac, replace the WireGuard public-key reference rather than deleting Clan's generated files. No other device's key needs to change. If browser authorization may have leaked, also rotate Tern's browser token during an announced **frontend-only** maintenance window and pair the remaining browsers again. The daemon owns the panes.
- Both frontend credentials grant control of the shared development shell. This is not read-only guest access or a per-user permission model. Do not hand out a peer's private key or browser link. Guests are outside this deployment.

## WSL host picker

The Mac's Tern desktop host picker also offers **`alex@wsl.fleet:944`**: the Linux guest of the Windows machine, as the account `alex`. It is a **separate host** with its own panes, not the `dev-01` workspace and not a shared session. Windows PowerShell and the Windows desktop are not on this host; a native Windows host is a separate design and is not included.

- **Path.** Native QUIC over the fleet WireGuard overlay only: `wsl.fleet` resolves to the IPv6 address derived from the Clan-generated `dev-01` public prefix and the per-host suffix (the `.value` files), the same address `wireguard-fleet.service` gives the guest. There is no public listener, relay, password, or fallback; if the overlay is down the host is unreachable.
- **Ingress.** `wsl-tern-ingress.service` installs the rules that allow only the Mac’s fleet address through the `fleet` interface. The frontend stays off if those rules cannot be installed. NixOS-WSL masks its general `firewall.service`; leave it masked.
- **Services.** `wsl-tern-daemon.service` owns the panes as `alex`. The QUIC frontend, `wsl-tern-native.service`, follows the daemon and fleet tunnel; stopping the tunnel does not stop the daemon. `wsl-tern-install.service` publishes the verified executable to `/var/lib/wsl-tern-bin/tern`. The frontend keeps its separate host identity under `/var/lib/wsl-tern-native` (owner `alex`, mode `0700`).
- **Authorization.** Only the Mac's existing configured Tern Ed25519 public key (`nativePublicKey` of `macbook` in the [peer inventory](../fleet/tern-workspace.nix)) is allowed. No SSH authorization is added or changed, and there is no unauthenticated mode.
- **Binary.** Stage the official Linux x86-64 **Tern 0.9.30** in WSL as `alex`: extract `tern/tern` from your Stencil download to `~/.local/bin/tern` (mode `0755`). Do not overwrite an existing installation. The Windows desktop app does not supply this executable, and dev-01 stays on 0.9.29. Without the executable, the units stay off. If you stage it after applying WSL, run `sudo systemctl start wsl-tern-daemon.service` to verify and publish it and start the services.
- **Guest lifetime.** The host is reachable only while the WSL guest is running. A guest shutdown ends running processes; reopening restores saved layout, not those processes.

**First connection.** Choose **Add remote host**, not setup over SSH, and enter `alex@wsl.fleet:944`. Compare the prompt with the real host key fingerprint read independently in a trusted WSL shell, and stop if it differs:

```sh
state=/var/lib/wsl-tern-native
systemctl is-active --quiet wsl-tern-native.service &&
  test -s "$state/host_key" &&
  env HOME="$state" TERN_CONFIG_DIR="$state" \
    XDG_RUNTIME_DIR=/run/wsl-tern-native \
    /var/lib/wsl-tern-bin/tern remote host-key --state-dir "$state"
```

Share only the fingerprint; never read out or copy `host_key`. Verify once with `systemctl is-active wireguard-fleet wsl-tern-daemon wsl-tern-native`.

**Deployment and Manifold.** Old Manifold sessions are not migrated into Tern. Before applying WSL, review `atyrode apply wsl --preview-json` and save or exit any Manifold sessions that the activation would retire. Do not override a blocked preview.

## Mac host picker (Windows to Mac)

The native Windows Tern desktop can also connect to the Mac's own Tern: a **separate host** from the `dev-01` shared workspace. It uses the Mac's existing `/Applications/Tern.app` (0.9.30). Nothing is downloaded, replaced or restarted, and no SSH access or PF rule is added. The user-scoped launch agent `dev.atyrode.tern-mac-host` runs `remote serve --user --relay none` on UDP/944, bound to the Mac's fleet address only, and authorizes only the Windows desktop's Tern key (`peers.windows.nativePublicKey` in the [peer inventory](../fleet/tern-workspace.nix)). There is no public shell or relay. It works only while the Mac is awake with its owner logged in and the app present, and `dev-01` and the Mac's fleet tunnel are up.

On Windows, create a **separate** native WireGuard profile named `atyrode-mac`. It must not reuse `atyrode-tern`, `wsl`, or any other profile. Let WireGuard generate the private key locally and never paste it anywhere. Its public key must equal `clientWireGuardPublicKey` in [`fleet/mac-tern-host.nix`](../fleet/mac-tern-host.nix), which the hub admits; if it differs, stop and publish the reviewed public key first. From the checkout root, print the public fields (no secret is read):

```sh
nix eval --raw --file fleet/mac-tern-host.nix --apply \
  'h: "Address = ${h.clientAddress}/128\n\n[Peer]\nPublicKey = ${h.serverPublicKey}\nAllowedIPs = ${h.address}/128\nEndpoint = ${h.endpoint}:${toString h.endpointPort}\nPersistentKeepalive = 25\n"'
```

Paste these fields after `PrivateKey` in the existing `[Interface]` section. Keep the private key WireGuard generated; remove any `ListenPort` line.

Leave DNS and listen port unset. `AllowedIPs` is only the Mac's single `/128`: Windows carries no other fleet route. The hub (`dev-01`, [`modules/nixos/mac-tern-fleet.nix`](../modules/nixos/mac-tern-fleet.nix)) limits this peer to client-to-Mac UDP/944 and back and drops every other packet to or from the Windows address. No global firewall or WSL setting changes.

If a manual networkd reload on `dev-01` drops the Windows peer, restart `mac-tern-fleet-peer.service` on `dev-01` to re-enroll it. A missing peer fails closed; do not widen the tunnel or the firewall to recover it.

**First connection.** A `.fleet` name for the Mac is not known to resolve natively on Windows, so do not rely on one. For the one-time setup, use the bracketed IPv6 literal printed as `AllowedIPs` (without `/128`) in Tern's **Add remote host** (not setup over SSH): `<mac-username>@[<that-address>]:944`, where the username is the Mac account that is logged in. Switch to a name only after verifying it resolves on Windows natively.

Before trusting the prompt, read the Mac's host-key fingerprint independently, from a trusted shell on the Mac as its owner. This reads the state directory the launch agent uses, `~/.local/state/tern-mac-host`, and the executable the app bundle declares:

```sh
state="$HOME/.local/state/tern-mac-host"
app=/Applications/Tern.app
exe="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")" &&
  test -s "$state/host_key" &&
  "$app/Contents/MacOS/$exe" remote host-key --state-dir "$state"
```

Compare only the `SHA256:` fingerprint with the Windows prompt and stop if it differs. Never print, copy or share `host_key`.

**Not yet physically verified:** the Windows `atyrode-mac` tunnel, the hub peer on `dev-01`, the Mac listener, the Tern prompt and fingerprint, and a real attach have not been exercised on hardware. In particular, `remote host-key` output on the Mac and the bracketed-literal host entry are unconfirmed. Treat a connection and a typed command in a Mac pane as the acceptance test; a mere tunnel handshake is not.

{ pkgs }:

let
  inherit (import ./harness.nix { inherit pkgs; }) mkScenario;
in
mkScenario "darwin-volumes" ''
  # An fstab entry naming a volume that no longer resolves is dropped, and
  # the file it came from is archived first so the edit is reversible.
  darwin_fixture darwin-fstab-repair
  export PATH="$fresh_tools:$base_path"
  printf 'Nix Store\tdisk3s7\tLIVE-UUID\n' > "$FAKE_VOLUMES"
  printf 'UUID=DEAD-UUID /nix apfs rw,noauto,nobrowse,nosuid,noatime,owners\n' \
    > "$etc/fstab"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/fstab-plan.out"
  grep -F "Drop the dead /nix entry from $etc/fstab" "$TMPDIR/fstab-plan.out" >/dev/null
  test -f "$etc/fstab"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  # macOS ships without /etc/fstab, so an emptied file is removed outright.
  test ! -e "$etc/fstab"
  archive="$(find "$XDG_STATE_HOME/atyrode/bootstrap/repairs" -name 'fstab.*' -print -quit)"
  grep -F 'UUID=DEAD-UUID /nix apfs' "$archive" >/dev/null

  # An orphaned Nix Store volume is renamed, never deleted: the installer
  # finds volumes by label, so a rename is enough to route it onto its
  # fresh-create path, and the data stays on disk.
  darwin_fixture darwin-orphaned-volume-repair
  export PATH="$fresh_tools:$base_path"
  printf 'Nix Store\tdisk3s7\tSTALE-UUID\n' > "$FAKE_VOLUMES"
  # The fstab line names the volume about to be renamed. A rename keeps the
  # UUID, so resolvability alone would not catch it; it must still be planned.
  printf 'UUID=STALE-UUID /nix apfs rw,noauto,nobrowse,nosuid,noatime,owners\n' \
    > "$etc/fstab"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/volume-plan.out"
  grep -F 'Retire the orphaned Nix Store volume disk3s7' "$TMPDIR/volume-plan.out" >/dev/null
  grep -F 'nothing on it is deleted' "$TMPDIR/volume-plan.out" >/dev/null
  grep -F "Drop the dead /nix entry from $etc/fstab" "$TMPDIR/volume-plan.out" >/dev/null
  grep -F 'Nix Store	disk3s7' "$FAKE_VOLUMES" >/dev/null
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  # Same device, same UUID, new label: nothing was destroyed.
  grep -E "^Nix Store \(orphaned [0-9TZ]+\)	disk3s7	STALE-UUID	" "$FAKE_VOLUMES" >/dev/null
  undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
  grep -F "diskutil rename 'disk3s7' 'Nix Store'" "$undo" >/dev/null

  # An unmounted volume is not a hypothetical: recovery unmounts to free
  # /nix, so the very next run meets one. diskutil renames through the
  # mounted filesystem, so the rename must mount it first and leave it
  # unmounted afterwards - occupying /nix would block the installer.
  darwin_fixture darwin-unmounted-volume-repair
  export PATH="$fresh_tools:$base_path"
  printf 'Nix Store\tdisk3s7\tSTALE-UUID\tno\n' > "$FAKE_VOLUMES"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  grep -E "^Nix Store \(orphaned [0-9TZ]+\)	disk3s7	STALE-UUID	no	$" "$FAKE_VOLUMES" >/dev/null
  test -e "$FAKE_INSTALL_EXECUTED"

  # The installer encrypts the volume it creates and keeps the passphrase in
  # the System keychain, so an unmounted one is also locked. Unlocking with
  # that passphrase is what keeps this repair non-destructive.
  darwin_fixture darwin-locked-volume-repair
  export PATH="$fresh_tools:$base_path"
  export FAKE_VOLUME_PASSPHRASE=correct-horse
  export FAKE_KEYCHAIN_UUID=STALE-UUID
  printf 'Nix Store\tdisk3s7\tSTALE-UUID\tno\tlocked\n' > "$FAKE_VOLUMES"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  grep -E "^Nix Store \(orphaned [0-9TZ]+\)	disk3s7	STALE-UUID	no	$" "$FAKE_VOLUMES" >/dev/null
  test -e "$FAKE_INSTALL_EXECUTED"
  grep -F "diskutil rename 'disk3s7' 'Nix Store'" \
    "$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log" >/dev/null
  unset FAKE_VOLUME_PASSPHRASE FAKE_KEYCHAIN_UUID

  # No key means no mount, and no mount means no rename. Leaving it labelled
  # Nix Store routes the installer onto the path that crashes, so it is
  # deleted - the store-database check already proved no live install is on
  # it, and a Nix store re-downloads. The journal records that this one does
  # not undo.
  darwin_fixture darwin-locked-volume-no-key
  export PATH="$fresh_tools:$base_path"
  printf 'Nix Store\tdisk3s7\tSTALE-UUID\tno\tlocked\n' > "$FAKE_VOLUMES"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/locked-plan.out"
  grep -F 'it is deleted instead' "$TMPDIR/locked-plan.out" >/dev/null
  # Deleting a volume is the one irreversible repair, so the run must say
  # what it observed rather than only that it deleted something.
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" \
    > "$TMPDIR/locked-apply.out"
  grep -F 'Reason:' "$TMPDIR/locked-apply.out" >/dev/null
  grep -F 'no passphrase for STALE-UUID in the System keychain' \
    "$TMPDIR/locked-apply.out" >/dev/null
  test ! -s "$FAKE_VOLUMES"
  test -e "$FAKE_INSTALL_EXECUTED"
  undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
  grep -F 'deleted the locked Nix Store volume disk3s7' "$undo" >/dev/null
  grep -F 'undo: none:' "$undo" >/dev/null

  # A volume carrying a live store is in use, not orphaned, and is never
  # touched however the rest of the machine looks.
  darwin_fixture darwin-live-volume-untouched
  export PATH="$fresh_tools:$base_path"
  printf 'Nix Store\tdisk3s7\tLIVE-UUID\n' > "$FAKE_VOLUMES"
  mkdir -p "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/db"
  : > "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/db/db.sqlite"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/live-volume-plan.out"
  grep -Fq 'Rename the orphaned' "$TMPDIR/live-volume-plan.out" && exit 1
  grep -F 'Nix Store	disk3s7' "$FAKE_VOLUMES" >/dev/null
''

# Running the fleet

The commands that come up in a normal week, and the one thing each of them is
for. Everything here is `atyrode`: it is the only front door, and it wraps
`clan`, `nh`, `home-manager` and `sops` so that a machine never needs a
different command depending on what it is.

Concepts live elsewhere and are linked where they matter: what a machine is
made of is [hosts.md](hosts.md), who can read a secret is
[secrets.md](secrets.md), and the reasoning behind the fleet's shape is
[ADR 0008](adr/0008-fleet-shape-and-substrate.md).

## Converging a machine

```sh
atyrode apply            # this machine, from the latest published main
atyrode apply --plan     # what it would do, without doing it
```

`apply` is the whole of routine operation. It activates the published flake,
so no checkout is needed and the command behaves the same from any directory
on any machine. It prints a numbered plan, then walks it: every command that
changes something is shown as its argv before it runs, and every step ends in
one verdict. Nothing else is expected to be run by hand on a normal day.

A machine the operator is not sitting at is the same operation over SSH:

```sh
atyrode fleet plan dev-01     # vars, reachability, evaluation; activates nothing
atyrode fleet apply dev-01    # build here, activate there, verify
```

Clan builds the closure on the machine running the command and activates it on
the target, so the target needs no toolchain and no checkout. Where it is
reached is the machine's own `clan.core.networking.targetHost`: a deployment
cannot be aimed somewhere the reviewed configuration does not name.

### Machines left alone

A fleet member converges on its own: every night a per-machine timer runs
`atyrode apply --unattended` against the published `main`, and a machine that
slept through its slot runs it when it wakes. Unattended, apply asks nothing
and builds nothing CI has not published. It does nothing when the machine
already runs `main`, activates when the disruption report is safe and
activation can elevate without a password (dev-01, WSL), and otherwise
**holds** and says why -- on a Mac, always, because nix-darwin's switch asks
for sudo. Every run leaves one receipt, `~/.local/state/atyrode/converge.json`,
and that is what the login shell reads when it prints a muted line about a
hold or a failure. `atyrode doctor` compares the revision this machine runs
with `main` and reports the drift, with the receipt's own remedy when there is
one. `atyrode apply` from a terminal is the manual "now"; the timer is the
floor beneath it.

## Asking a machine what is wrong

```sh
atyrode doctor           # every family, one verdict
atyrode doctor --json
```

`doctor` is the only definition of a healthy machine, and it changes nothing.
It reports six families: the host's identity against the registry, the system
boundary (login shell, Nix policy, container engine, and on macOS the residue
of an interrupted Nix installation), Git authentication and signing, the tools
a capability promises, the provisioning surfaces this machine declares, and
the generated agent context. Exit 69 means a family is incomplete, and every
incomplete row carries the command that clears it.

`atyrode apply` runs the provisioning review as its last step, so a surface
that is not configured is offered rather than merely reported.

## Adding a machine

1. Register it in [`fleet/hosts.nix`](../fleet/hosts.nix): a name that says
   what the machine is, its system, activation and capabilities. A clan
   machine (nix-darwin or NixOS) also gets a directory under
   `fleet/machines/<name>/` for its disk, boot, network and hardware report.
2. Open a pull request. CI builds the closure for every system and publishes
   what it compiled, so the machine downloads rather than builds.
3. On an operator device, in a checkout: `clan vars generate <name>`. This
   mints the machine's age key and its declared secrets, encrypts them to the
   `admins` group, and commits. `atyrode provision machine-key` is the same
   thing run from the machine itself when it is already an operator device.
4. On the machine, `atyrode apply` — or `atyrode fleet apply <name>` from
   elsewhere. The first step places the machine key so the activation that
   follows can decrypt the machine's vars.

A machine with no Nix at all starts one step earlier, with
[bootstrap.md](bootstrap.md).

## Adding a device you edit secrets from

Every fixed machine can be an operator device; none is special.

```sh
atyrode operator init    # mint this device's key, print the two clan commands
```

The key is minted where it is used — inside the Secure Enclave on a Mac, an
age file elsewhere — and never leaves the machine. The command prints the two
`clan secrets` lines that register the device as a user in the `admins` group;
run them in a checkout and commit. From then on every value in the repository
is readable by that device, because everything is encrypted to the group.

`atyrode operator show` says whether this device is registered, and
`atyrode doctor provisioning` carries the same as a surface.

## Adding a secret

A secret is an output of a `clan.core.vars.generators.<name>` entry in a
machine's Nix configuration: a script, its inputs, and the files it produces,
each marked secret or not. Declare it, then on an operator device run
`clan vars generate <machine>` and commit; `atyrode apply` on the machine
delivers it at activation. Nothing is fetched at runtime and no ceremony
holds a session open. The details, including what may read what, are in
[secrets.md](secrets.md).

## Losing a device

```sh
clan secrets groups remove-user admins alex-<device>
clan secrets users remove alex-<device>
```

Clan re-encrypts every value the group could read without that device and
commits, so from that revision on the device can decrypt nothing new. What it
already read is what a leaked laptop always costs; rotate the values that
matter. The machine keys are unaffected, because a machine key is the
machine's, not the operator's.

## Break-glass

Bitwarden is not part of routine operation. It holds the recovery identity
that is registered in `admins` alongside every device, so a fleet whose
devices are all lost is still readable:

```sh
atyrode vault login      # pins the right server, then authenticates
atyrode vault get NAME
```

`atyrode doctor` mentions Bitwarden nowhere else, and `bw status` may read
`unauthenticated` on every machine without anything degrading.

## Keeping the machine small

```sh
atyrode lifecycle        # what generations and store roots exist
atyrode clean --yes      # collect what nothing points at
atyrode rollback         # the previous generation, activated
```

Rollback is why flipping something off is cheap: the old generation is still
there until it is collected, so a change that turns out wrong is one command
away from undone.

## Running something without installing it

```sh
atyrode run                    # the reviewed catalog, with a reason each
atyrode run tokei -- src       # run one; arguments after -- are its own
```

The catalog ([`fleet/catalog.nix`](../fleet/catalog.nix)) is a list of software
worth remembering, not a list of software installed anywhere. A run leaves no
generation and no GC root, so the next `atyrode clean` reclaims it and the
machine is exactly what the registry said it was. Nothing is committed, which
is the point: a tool borrowed for an afternoon was never a fact about this
machine.

An entry names the systems it runs on, because a package that has no macOS
build must not be offered on the Mac. Mac applications are a different
question: they arrive as declared Homebrew casks, so wanting one is a change
to [the registry](../fleet/hosts.nix) and a commit, not a run.

The same list is the Catalog workspace in `atyrode` with no arguments, which
is where it is worth using: the point of the catalog is not typing fewer
characters, it is not having to remember what the tool was called.

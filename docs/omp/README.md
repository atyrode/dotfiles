# OMP feature wiki

> - **Audited:** 2026-07-15
> - **Repository pin:** `omp` v17.0.0
> - **Upstream release:** [v17.0.0](https://github.com/can1357/oh-my-pi/releases/tag/v17.0.0) (2026-07-15)
> - **Audit range:** v16.0.0 through v17.0.0, plus the v17.0.0 CLI help and documentation

This is the compact “did you know this exists?” index for the OMP binary used by
these dotfiles. It is for operators deciding what to invoke and for agents that
need to discover an OMP capability before proposing new wrapper code.

## Choose the correct surface first

The [CLI reference](cli.md) describes **plain upstream `omp` v17.0.0**. These
repository launchers are not interchangeable:

| Invoke | Authentication and state | Configuration and policy |
| --- | --- | --- |
| `omp` | The selected OMP `--profile`, or OMP's default state root | Plain, mutable upstream configuration under `~/.omp`; no repository-managed policy is injected |
| `code` | The selected auth-broker vault (`mine`, `mum`, or `victor`) supplies credentials while every trusted launch shares client profile `default`; `a` cycles enabled vaults and `v` manages them | Always launches through the managed layers: Enter runs the generated routing profile (including its task-agent model overrides), `m` runs the managed defaults with no overlay. Plain `omp` is never launched via `code` |
| `omp-managed` | The explicit OMP `--profile`, or OMP's default state root | Injects the Nix-owned defaults, platform extensions, and enforced policy; maintenance subcommands bypass overlay injection but remain subject to repository intercepts/guards |
| `ompu` | Always the fixed `untrusted` profile | Fixed credential-sanitized untrusted sandbox; it never inherits a personal vault selected in `code` |

Read [Agent tools](../agent-tools.md) for the exact layering, ownership, and
trust-boundary rules. Never copy a plain-`omp` example into `omp-managed` or
`ompu` documentation without checking the wrapper behavior.

## Pages

- [CLI reference](cli.md) — launch arguments, command catalog, built-in tools,
  and invocation examples.
- [Capability field guide](features.md) — high-value workflows, built-in slash
  commands, keybindings, and release-backed feature discoveries.

For the fastest live discovery:

```console
$ omp --help                 # plain upstream launch flags and shell commands
$ omp <command> --help       # one shell command
```

Inside an interactive upstream session:

```text
/help                        # active slash commands, including extensions
/hotkeys                     # active chords after user remaps/extensions
/tools                       # tools currently visible to the agent
/context                     # estimated context-use breakdown
/settings                    # merged interactive settings
```

Most of these commands remain available when a wrapper reaches the upstream
TUI, subject to its injected settings and policy. One important exception is
`/settings`: the managed extension intercepts it in `omp-managed` and generated
managed launches, then directs the operator to the repository-owned edit paths.

## Audit provenance

Claims in this wiki were checked against:

1. the repository pin in [`pkgs/omp/default.nix`](../../pkgs/omp/default.nix);
2. the output of the packaged `omp v17.0.0 --help` and each listed shell
   command's `--help`;
3. the upstream documentation at the immutable
   [`v17.0.0` tag](https://github.com/can1357/oh-my-pi/tree/v17.0.0/docs);
4. upstream release notes from
   [v16.0.0](https://github.com/can1357/oh-my-pi/releases/tag/v16.0.0) through
   [v17.0.0](https://github.com/can1357/oh-my-pi/releases/tag/v17.0.0); and
5. the repository-owned wrapper behavior in [Agent tools](../agent-tools.md).

No upstream release newer than v17.0.0 had been published when this audit was
written. Availability in upstream `main` or a newer release is not proof that a
feature exists in the packaged binary.

## Refreshing the wiki after a pin update

1. Update the version and audit date above.
2. Compare `omp --help` and every `omp <command> --help` with
   [CLI reference](cli.md).
3. Review all release notes after the previous pin; fold user-facing additions,
   changes, removals, and deprecations into [the field guide](features.md).
4. Re-check linked upstream docs at the new immutable tag.
5. Re-check `code`, `omp-managed`, and `ompu` independently so upstream flags
   are not mistaken for wrapper guarantees.
6. Run the repository documentation-link and formatting checks.

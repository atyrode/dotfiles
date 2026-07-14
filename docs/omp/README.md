# OMP feature wiki

> - **Audited:** 2026-07-14
> - **Repository pin:** `omp` v16.4.8
> - **Upstream release:** [v16.4.8](https://github.com/can1357/oh-my-pi/releases/tag/v16.4.8) (2026-07-12)
> - **Audit range:** v16.0.0 through v16.4.8, plus the v16.4.8 CLI help and documentation

This is the compact “did you know this exists?” index for the OMP binary used by
these dotfiles. It is for operators deciding what to invoke and for agents that
need to discover an OMP capability before proposing new wrapper code.

## Choose the correct surface first

The [CLI reference](cli.md) describes **plain upstream `omp` v16.4.8**. These
repository launchers are not interchangeable:

| Invoke | Authentication and state | Configuration and policy |
| --- | --- | --- |
| `omp` | The selected OMP `--profile`, or OMP's default state root | Plain, mutable upstream configuration under `~/.omp`; no repository-managed policy is injected |
| `code` | The `mine`/`mum` combination visible in its usage widget; press `a` to switch | With no generated input, launches plain `omp`; with a prompt or changed dial, launches a generated routing profile through the managed layers |
| `omp-managed` | The selected OMP `--profile` | Injects the Nix-owned defaults, platform extensions, and enforced policy; maintenance subcommands bypass overlay injection but remain subject to repository intercepts/guards |
| `ompu` | Always the fixed `untrusted` profile | Fixed credential-sanitized untrusted sandbox; does not inherit the personal profile selected in `code` |

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
2. the output of the packaged `omp v16.4.8 --help` and each listed shell
   command's `--help`;
3. the upstream documentation at the immutable
   [`v16.4.8` tag](https://github.com/can1357/oh-my-pi/tree/v16.4.8/docs);
4. upstream release notes from
   [v16.0.0](https://github.com/can1357/oh-my-pi/releases/tag/v16.0.0) through
   [v16.4.8](https://github.com/can1357/oh-my-pi/releases/tag/v16.4.8); and
5. the repository-owned wrapper behavior in [Agent tools](../agent-tools.md).

Upstream had already published
[v16.5.0](https://github.com/can1357/oh-my-pi/releases/tag/v16.5.0) and
[v16.5.1](https://github.com/can1357/oh-my-pi/releases/tag/v16.5.1) when this
audit was written. They are intentionally excluded because these dotfiles still
package v16.4.8. Availability in upstream `main` or a newer release is not proof
that a feature exists in the packaged binary.

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

# atyrode-preview

`atyrode-preview-parser` turns the human-readable diff report `nh` prints for a
planned generation into the JSON document `atyrode apply --preview-json` emits:
`schemaVersion: 1`, the host, system, and full resolved revision the caller
supplies with `--host`, `--system`, and `--revision`, a duration-free `status`,
package changes grouped as `added`, `updated`, and `removed` (each with its
granular `changeKind`, versions, and size delta), the store-path, closure-size,
and generation facts nh reports, the `disruption` block, and a `technical`
report stripped of spinner frames and terminal controls. `nh` does not expose
this report as JSON, which is the only reason this package exists; unknown
package status lines fail closed rather than dropping a change.

Its only caller is `pkgs/atyrode/lib/apply.sh`, which pipes nh's output to it on
stdin and passes the three flags. `nix build .#atyrode-preview` runs the fixture
tests covering every current dix change kind, totals, generation paths,
no-change output, terminal controls, and format drift. Version 1 may gain
optional fields; removing or changing the meaning of a field requires
incrementing `schemaVersion`.

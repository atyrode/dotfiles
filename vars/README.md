# vars

Where clan vars land: `per-machine/<host>/<generator>/<file>/` and
`shared/<generator>/<file>/`, each holding either a public `value` or an
age-encrypted `secret` written by `clan vars generate` on the Mac and never
by hand. The readers of a `secret` are the machine it belongs to and the
users registered under [`sops/`](../sops/README.md); the `secret-shapes`
check refuses a `secret` file that is not sops ciphertext.

No generator is declared yet, so nothing has been generated. The first one
arrives with the first surface that leaves Bitwarden (ADR 0008, step 3).

# secrets

Age-encrypted values, committed. `shared.yaml` is readable by every registered
machine; `<host>.yaml` by that machine alone. Every file is also readable by
the operator, whose keys are the only ones that edit: the daily identity in
the Mac's Secure Enclave (`sops secrets/<file>.yaml`, with Touch ID) and the
recovery key whose only copy is the Bitwarden break-glass note.

The audience is `.sops.yaml` at the repository root, and nothing else: a
machine reads a file because its recipient is listed there, and stops reading
it after `sops updatekeys` without it. Each machine registers its own key with
`atyrode identity init`; the model, the ceremony and what a leak costs are in
[docs/secrets.md](../docs/secrets.md).

No file exists yet. The first arrives with the first surface that leaves
Bitwarden (ADR 0008, step 3).

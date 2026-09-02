---
name: no-shell-text-surgery
description: "Never edit files via python/sed heredocs or search source with shell grep — use the harness edit/ast_edit/write/grep/read tools"
condition: ["python3?\\s+-\\s*<<'?PYEOF", "python3?\\s+-c\\s", "\\b(?:grep|sed)\\s+-[A-Za-z]+\\S*\\s+[^|\\n]*(?:src|tests|docs|design)/"]
scope: "tool:bash"
---

Do not shell out to `python3 - <<'PYEOF'`, `python3 -c`, `sed`, or `grep` to modify or inspect repository files. This harness has dedicated, optimized tools:

- **Edit files** → `edit` (hashline anchors) or `ast_edit` (structural codemods); whole-file rewrites → `write`.
- **Search content** → the built-in `grep` tool (Rust regex, snapshot tags for anchored edits).
- **Read files/ranges** → `read` with `path:start-end` selectors.

Reserve `bash` for running real binaries (test runners, git, docker) or short fact-computing pipelines on command output — never for text surgery on tracked files.

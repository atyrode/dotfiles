#!/usr/bin/env python3
"""Extract ground-truth (first prompt, settings-in-effect) pairs from omp sessions.

Reads ~/.omp/agent/sessions/*/*.jsonl and, for each session, emits the operator's
FIRST user message together with the model and thinking level that were in effect
when they sent it (the latest model_change / thinking_level_change seen before
that message, in file order).

The output is RAW, un-anonymized operator content — it is written to
--out (default raw_groundtruth.json) which .gitignore excludes. It MUST NOT be
committed. The committed, hand-anonymized dataset lives in dataset.json; this
script exists so that curation is reproducible and auditable, not so its output
ships.

Usage:
    python3 extract_groundtruth.py [--sessions DIR] [--out FILE]
"""
import argparse
import glob
import json
import os
import sys
from collections import Counter


def first_user_text(msg):
    """Pull plain text out of a message's content (string or block list)."""
    content = msg.get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        out = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                out.append(block.get("text", ""))
        return "".join(out).strip()
    return ""


def extract_session(path):
    """Return {model, thinking, first, len, path} or None if no user prompt."""
    model = thinking = first = None
    session_cwd = None
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                etype = ev.get("type")
                if etype == "session":
                    session_cwd = ev.get("cwd")
                elif etype == "model_change":
                    model = ev.get("model")
                elif etype == "thinking_level_change":
                    thinking = ev.get("thinkingLevel")
                elif etype == "message" and first is None:
                    msg = ev.get("message", {})
                    if msg.get("role") == "user":
                        text = first_user_text(msg)
                        if text:
                            first = text
    except OSError as err:
        print(f"skip {path}: {err}", file=sys.stderr)
        return None
    if not first:
        return None
    return {
        "path": os.path.basename(path),
        "cwd": session_cwd,
        "model": model,
        "thinking": thinking,
        "len": len(first),
        "first": first,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--sessions",
        default=os.path.expanduser("~/.omp/agent/sessions"),
        help="omp sessions root (default: ~/.omp/agent/sessions)",
    )
    ap.add_argument(
        "--out",
        default=os.path.join(os.path.dirname(__file__), "raw_groundtruth.json"),
        help="where to write the raw (un-anonymized, gitignored) pairs",
    )
    args = ap.parse_args()

    paths = sorted(glob.glob(os.path.join(args.sessions, "*", "*.jsonl")))
    rows = [r for r in (extract_session(p) for p in paths) if r]

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=1, ensure_ascii=False)

    print(f"sessions scanned : {len(paths)}")
    print(f"with a first prompt: {len(rows)}")
    print(f"model  : {Counter(r['model'] for r in rows).most_common()}")
    print(f"thinking: {Counter(r['thinking'] for r in rows).most_common()}")
    print(f"wrote {args.out} (RAW — do not commit)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Refresh the factual fields in omp/models.yml from omp — the source of truth.

omp is the authority for what a model costs and how fast it runs; models.yml is
only a committed cache the sandboxed Nix build can read (the build has no network,
creds, or ~/.omp). This script re-pulls the facts so we never hand-maintain them:

  cost_in / cost_out / context / thinking   <- `omp models --json`
  speed (tok/s) / ttft (s)                   <- `omp bench --json`  (live, costs API $)

Only those fields are rewritten; the curated fields (pool, tier, bucket, role) and
every comment are preserved. Run it from the repo root:

  nix run .#refresh-model-facts                 # cost + speed (benches every model)
  nix run .#refresh-model-facts -- --skip-bench # cost/context/thinking only (free)
  nix run .#refresh-model-facts -- --runs 3     # average speed over 3 bench runs

A model whose bench fails (e.g. its quota is maxed) keeps its existing speed/ttft
and prints a warning — re-run once the bucket resets.
"""
import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

from ruamel.yaml import YAML

POOL_PROVIDER = {"O": "openai-codex", "A": "anthropic"}


def omp_models():
    out = subprocess.run(["omp", "models", "--json"], capture_output=True, text=True, check=True).stdout
    idx = {}
    for m in json.loads(out)["models"]:
        idx[(m["provider"], m["id"])] = m
    return idx


def bench_from(models_data):
    """Index a bench --json payload by selector, keeping only successful runs."""
    out = {}
    for m in models_data:
        avg = m.get("average") or {}
        r0 = (m.get("results") or [{}])[0]
        if r0.get("ok") and avg.get("tokensPerSecond"):
            out[m["model"]] = avg
    return out


def omp_bench(selectors, runs, max_tokens):
    cmd = ["omp", "bench", *selectors, "--json", "--runs", str(runs), "--max-tokens", str(max_tokens)]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return bench_from(json.loads(out)["models"])


def omp_stats():
    """Per-model historical aggregate (what `/model` shows) — the fallback for a
    model `omp bench` can't reach live (e.g. a maxed quota). Keyed by provider/id.
    Note: stats are thinking-blended real usage, not a clean benchmark."""
    out = subprocess.run(["omp", "stats", "--json"], capture_output=True, text=True, check=True).stdout
    out = out[out.index("{"):]  # skip the "Syncing…" preamble
    res = {}
    for m in json.loads(out).get("byModel", []):
        tps, ttft = m.get("avgTokensPerSecond"), m.get("avgTtft")
        if tps and ttft:
            res[f"{m['provider']}/{m['model']}"] = {"tokensPerSecond": tps, "ttftMs": ttft}
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default="omp/models.yml", help="path to models.yml (default: omp/models.yml under CWD)")
    ap.add_argument("--runs", type=int, default=2, help="bench requests per model, averaged")
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--skip-bench", action="store_true", help="only refresh cost/context/thinking (no API calls)")
    ap.add_argument("--bench-json", help="reuse a saved `omp bench --json` payload instead of running it")
    args = ap.parse_args()

    path = Path(args.file)
    yaml = YAML()
    yaml.preserve_quotes = True
    doc = yaml.load(path.read_text())
    models = doc["models"]

    mi = omp_models()
    for key, m in models.items():
        prov = POOL_PROVIDER[m["pool"]]
        om4 = mi.get((prov, m["id"]))
        if not om4:
            print(f"warn: {key} ({prov}/{m['id']}) not found in `omp models`", file=sys.stderr)
            continue
        m["cost_in"] = om4["cost"]["input"]
        m["cost_out"] = om4["cost"]["output"]
        m["context"] = om4["contextWindow"]
        th = om4.get("thinking") or []
        if th:
            m["thinking"] = f"{th[0]}→{th[-1]}"

    if not args.skip_bench:
        if args.bench_json:
            bench = bench_from(json.loads(Path(args.bench_json).read_text())["models"])
        else:
            selectors = [f"{POOL_PROVIDER[m['pool']]}/{m['id']}" for m in models.values()]
            bench = omp_bench(selectors, args.runs, args.max_tokens)
        stats = omp_stats()  # fallback for models bench couldn't reach
        for key, m in models.items():
            sel = f"{POOL_PROVIDER[m['pool']]}/{m['id']}"
            avg = bench.get(sel)
            if not avg and sel in stats:
                avg = stats[sel]
                print(f"note: {key} benched from `omp stats` history (bench unavailable)", file=sys.stderr)
            if not avg:
                print(f"warn: no bench or stats for {key} ({sel}); keeping existing speed/ttft", file=sys.stderr)
                continue
            m["speed"] = round(avg["tokensPerSecond"], 1)
            ttft = round(avg["ttftMs"] / 1000.0, 2)
            if "ttft" in m:
                m["ttft"] = ttft
            else:  # keep ttft next to speed, not appended at the end
                ks = list(m.keys())
                m.insert(ks.index("speed") + 1, "ttft", ttft)

    # stamp the refresh date (top-level; consumers read only `models`) so a CI
    # freshness check can nudge a re-run when the cache goes stale.
    today = datetime.date.today().isoformat()
    if "refreshed" in doc:
        doc["refreshed"] = today
    else:
        doc.insert(0, "refreshed", today)

    yaml.dump(doc, path.open("w"))
    print(f"refreshed {path} ({today})")


if __name__ == "__main__":
    main()

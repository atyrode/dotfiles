#!/usr/bin/env python3
"""Refresh cached model facts from OMP, preserving curated fields and comments.

  nix run .#refresh-model-facts                 # metadata + paid chat benchmarks
  nix run .#refresh-model-facts -- --skip-bench # metadata only (no model turns)
  nix run .#refresh-model-facts -- --runs 3     # mean of three chat runs per model

The single `refreshed` date attests ALL expected metadata and speed/TTFT values.
Skipped, failed or malformed measurements retain their old values and date.
Partial failures exit nonzero after saving valid updates; --skip-bench is an
intentional partial refresh and exits zero when all metadata was available.
Saved --bench-json must use the pinned OMP chat profile, not mixed/cache runs.
"""
import argparse
import datetime
import json
import math
import subprocess
import sys
from pathlib import Path

from ruamel.yaml import YAML

POOL_PROVIDER = {"O": "openai-codex", "A": "anthropic", "D": "deepseek"}


def positive_number(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def positive_integer(value):
    return type(value) is int and value > 0


def model_rows(payload):
    if not isinstance(payload, dict) or not isinstance(payload.get("models"), list):
        raise ValueError("expected a JSON object with a models array")
    return payload["models"]


def omp_models():
    result = subprocess.run(["omp", "models", "--json"], capture_output=True, text=True, check=True)
    idx = {}
    for model in model_rows(json.loads(result.stdout)):
        if not isinstance(model, dict) or not all(isinstance(model.get(k), str) and model[k] for k in ("provider", "id")):
            raise ValueError("model metadata lacks provider/id")
        key = (model["provider"], model["id"])
        if key in idx:
            raise ValueError("duplicate provider/id in model metadata")
        idx[key] = model
    return idx


def sibling_prices(idx):
    """Highest valid reseller price by bare id, for unpriced provider rows."""
    out = {}
    for model in idx.values():
        cost = model.get("cost")
        if not isinstance(cost, dict) or not all(positive_number(cost.get(k)) for k in ("input", "output")):
            continue
        bare = model["id"].rsplit("/", 1)[-1].lower()
        if bare not in out or cost["input"] > out[bare][0]:
            out[bare] = (cost["input"], cost["output"])
    return out


def bench_from(payload):
    """Read OMP 18.1.14 stats means, only for complete successful chat runs.

    OMP emits JSON even when a request fails, and stats then average ONLY the
    successes. Accepting those stats would conceal incomplete measurements.
    Each valid metric can update independently; a missing one retains its cache.
    """
    rows = model_rows(payload)
    if payload.get("profile") != "chat" or "cache" in payload:
        raise ValueError("benchmark must use --profile chat (not mix/cache)")
    runs = payload.get("runs")
    if not positive_integer(runs):
        raise ValueError("benchmark lacks a positive runs count")
    out = {}
    seen = set()
    for model in rows:
        if not isinstance(model, dict) or not isinstance(model.get("selector"), str):
            raise ValueError("benchmark row lacks a selector")
        selector = model["selector"]
        if selector in seen:
            raise ValueError("duplicate benchmark selector")
        seen.add(selector)
        results = model.get("results")
        if not isinstance(results, list) or len(results) != runs or not all(
            isinstance(run, dict) and run.get("ok") is True and run.get("challenge") == "chat"
            for run in results
        ):
            continue
        stats = model.get("stats")
        if not isinstance(stats, dict):
            continue
        metrics = {}
        for field in ("tokensPerSecond", "ttftMs"):
            aggregate = stats.get(field)
            value = aggregate.get("mean") if isinstance(aggregate, dict) else None
            if positive_number(value) and all(positive_number(run.get(field)) for run in results):
                metrics[field] = value
        out[selector] = metrics
    return out


def omp_bench(selectors, runs, max_tokens):
    cmd = ["omp", "bench", *selectors, "--json", "--profile", "chat", "--runs", str(runs), "--max-tokens", str(max_tokens)]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode:
        print(f"warn: omp bench exited {result.returncode}; retaining unavailable measurements", file=sys.stderr)
    return bench_from(json.loads(result.stdout)), result.returncode == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--file", default="pkgs/omp-configured/config/models.yml", help="catalog path under CWD")
    ap.add_argument("--runs", type=int, default=2, help="chat requests per model, averaged")
    ap.add_argument("--max-tokens", type=int, default=256)
    source = ap.add_mutually_exclusive_group()
    source.add_argument("--skip-bench", action="store_true", help="metadata only; preserve the full-refresh date")
    source.add_argument("--bench-json", help="reuse a saved `omp bench --profile chat --json` payload")
    args = ap.parse_args()
    if args.runs <= 0 or args.max_tokens <= 0:
        ap.error("--runs and --max-tokens must be positive")

    path = Path(args.file)
    yaml = YAML()
    yaml.preserve_quotes = True
    doc = yaml.load(path.read_text())
    models = doc["models"]
    if not isinstance(models, dict) or not models:
        ap.error("catalog must contain a nonempty models mapping")

    try:
        metadata = omp_models()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: model metadata unavailable ({type(error).__name__}); catalog unchanged", file=sys.stderr)
        return 1
    siblings = sibling_prices(metadata)
    metadata_complete = True
    for key, model in models.items():
        provider = POOL_PROVIDER[model["pool"]]
        row = metadata.get((provider, model["id"]))
        if row is None:
            print(f"warn: {key}: metadata missing; keeping cost/context/thinking", file=sys.stderr)
            metadata_complete = False
            continue
        cost = row.get("cost")
        prices = (cost.get("input"), cost.get("output")) if isinstance(cost, dict) else (None, None)
        # Zero means unavailable in this routing catalog. Fall back to the same
        # model's valid reseller price, never replace an existing price with zero.
        if not all(positive_number(value) for value in prices):
            prices = siblings.get(model["id"].lower(), prices)
        for field, value in zip(("cost_in", "cost_out"), prices):
            if positive_number(value):
                model[field] = value
            else:
                print(f"warn: {key}: invalid/unavailable {field}; keeping existing value", file=sys.stderr)
                metadata_complete = False
        context = row.get("contextWindow")
        if positive_integer(context):
            model["context"] = context
        else:
            print(f"warn: {key}: invalid/unavailable context; keeping existing value", file=sys.stderr)
            metadata_complete = False
        thinking = row.get("thinking")
        if isinstance(thinking, list) and thinking and all(isinstance(level, str) and level for level in thinking):
            model["thinking"] = f"{thinking[0]}→{thinking[-1]}"
        else:
            print(f"warn: {key}: unavailable thinking range; keeping existing value", file=sys.stderr)
            metadata_complete = False

    bench_complete = False
    if not args.skip_bench:
        try:
            if args.bench_json:
                bench = bench_from(json.loads(Path(args.bench_json).read_text()))
                bench_complete = True
            else:
                selectors = [f"{POOL_PROVIDER[model['pool']]}/{model['id']}" for model in models.values()]
                bench, bench_complete = omp_bench(selectors, args.runs, args.max_tokens)
        except (OSError, ValueError) as error:
            print(f"warn: benchmark unavailable ({type(error).__name__}); keeping speed/ttft", file=sys.stderr)
            bench, bench_complete = {}, False
        for key, model in models.items():
            selector = f"{POOL_PROVIDER[model['pool']]}/{model['id']}"
            metrics = bench.get(selector, {})
            for field, metric, divisor, digits in (("speed", "tokensPerSecond", 1, 1), ("ttft", "ttftMs", 1000, 2)):
                if metric not in metrics:
                    print(f"warn: {key}: no complete valid benchmark for {field}; keeping existing value", file=sys.stderr)
                    bench_complete = False
                    continue
                value = round(metrics[metric] / divisor, digits)
                if value <= 0:
                    print(f"warn: {key}: {field} rounds to zero; keeping existing value", file=sys.stderr)
                    bench_complete = False
                elif field == "ttft" and field not in model:
                    model.insert(list(model).index("speed") + 1, field, value)
                else:
                    model[field] = value

    complete = metadata_complete and bench_complete
    if complete:
        today = datetime.date.today().isoformat()
        if "refreshed" in doc:
            doc["refreshed"] = today
        else:
            doc.insert(0, "refreshed", today)
    with path.open("w") as stream:
        yaml.dump(doc, stream)
    if complete:
        print(f"refreshed all model facts in {path} ({doc['refreshed']})")
    else:
        reason = "benchmarks skipped" if args.skip_bench else "incomplete facts"
        print(f"updated available facts in {path}; {reason}; full-refresh date unchanged ({doc.get('refreshed') or 'unknown'})")
    return 0 if complete or (args.skip_bench and metadata_complete) else 1


if __name__ == "__main__":
    sys.exit(main())

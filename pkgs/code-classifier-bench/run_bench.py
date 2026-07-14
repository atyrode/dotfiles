#!/usr/bin/env python3
"""Benchmark the code prompt->profile classifier across system-prompt variations.

For every (variation, dataset item) it sends the classifier's exact request to a
LIVE ollama daemon (temperature 0, same model as the picker) and parses the
model/thinking/advisor pick. It then compares each variation's picks against the
operator's ACTUAL settings from dataset.json and prints a divergence report:
per-variation alignment, and where the picks land relative to what the operator
chose (matched / over- / under-provisioned).

This is deliberately NOT wired into the nix build or flake checks: it needs a
running ollama daemon (network/model/RAM) that the build sandbox does not have.
Run it by hand on a machine with the daemon up:

    systemctl --user start ollama          # or: ollama serve &
    python3 run_bench.py                    # all variations, all items
    python3 run_bench.py --variations baseline glossary_system
    python3 run_bench.py --limit 5 --report report.md

Only depends on the stdlib + recipes.py (and a reachable ollama).
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

import recipes

HERE = os.path.dirname(os.path.abspath(__file__))


# ── ollama call ──────────────────────────────────────────────────────────────
def classify(endpoint, model, system, user, keep_alive, timeout):
    """One /api/chat call, temperature 0 (deterministic). Returns raw text."""
    body = json.dumps(
        {
            "model": model,
            "stream": False,
            "keep_alive": keep_alive,
            "options": {"temperature": 0},
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        }
    ).encode()
    req = urllib.request.Request(
        endpoint + "/api/chat", data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.load(resp)
    return data.get("message", {}).get("content", "")


def parse_pick(text):
    """Tolerant JSON extraction (first '{' .. last '}'), like the Go backend."""
    i, j = text.find("{"), text.rfind("}")
    if i < 0 or j <= i:
        return {}
    try:
        obj = json.loads(text[i : j + 1])
    except json.JSONDecodeError:
        return {}
    return obj if isinstance(obj, dict) else {}


# ── scoring ──────────────────────────────────────────────────────────────────
def ladder_delta(order, predicted, expected):
    """Signed step distance on an ordered ladder; None if either is off-ladder.

    Positive = predicted is HIGHER than the operator chose (over-provision),
    negative = lower (under-provision), 0 = exact.
    """
    if predicted not in order or expected not in order:
        return None
    return order.index(predicted) - order.index(expected)


def score_item(item, pick):
    """Compare one classifier pick against the operator's real settings."""
    exp_model, exp_elite = recipes.model_to_facet(item["op_model"] if item["op_model"] != "default" else None)
    exp_thinking = recipes.thinking_to_facet(None if item["op_thinking"] == "default" else item["op_thinking"])

    pred_model = pick.get("model")
    pred_thinking = pick.get("thinking")
    pred_advisor = pick.get("advisor")
    # deriveToggles (suggest.go): the picker treats smart + xhigh/max as the
    # critical/elite tier that turns the fable lead on.
    pred_elite = pred_model == "smart" and pred_thinking in ("xhigh", "max")

    return {
        "id": item["id"],
        "exp_model": exp_model,
        "exp_thinking": exp_thinking,
        "exp_elite": exp_elite,
        "pred_model": pred_model,
        "pred_thinking": pred_thinking,
        "pred_advisor": pred_advisor,
        "pred_elite": pred_elite,
        "model_match": pred_model == exp_model,
        "thinking_match": pred_thinking == exp_thinking,
        "model_delta": ladder_delta(recipes.MODEL_ORDER, pred_model, exp_model),
        "thinking_delta": ladder_delta(recipes.THINKING_ORDER, pred_thinking, exp_thinking),
        "parsed": bool(pick),
    }


def summarize(scores):
    n = len(scores)
    parsed = [s for s in scores if s["parsed"]]
    # An unparsed reply is a miss, not an exclusion: the picker gets no usable
    # suggestion when the model emits no JSON, so accuracy is over N — otherwise a
    # variation that only answers on the easy items looks deceptively strong.
    model_ok = sum(s["model_match"] for s in scores)
    think_ok = sum(s["thinking_match"] for s in scores)
    exact_ok = sum(s["model_match"] and s["thinking_match"] for s in scores)
    # over/under provision on the thinking ladder (the clearest cost signal),
    # measured only where the model actually answered.
    over = sum(1 for s in parsed if (s["thinking_delta"] or 0) > 0)
    under = sum(1 for s in parsed if (s["thinking_delta"] or 0) < 0)
    elite_items = [s for s in scores if s["exp_elite"]]
    elite_hit = sum(s["pred_elite"] for s in elite_items)
    dists = [abs(s["thinking_delta"]) for s in parsed if s["thinking_delta"] is not None]
    return {
        "n": n,
        "parsed": len(parsed),
        "parse_rate": len(parsed) / n if n else 0.0,
        "model_acc": model_ok / n if n else 0.0,
        "thinking_acc": think_ok / n if n else 0.0,
        "exact_acc": exact_ok / n if n else 0.0,
        "over_provision": over,
        "under_provision": under,
        "elite_items": len(elite_items),
        "elite_recall": elite_hit / len(elite_items) if elite_items else None,
        "mean_thinking_dist": sum(dists) / len(dists) if dists else 0.0,
    }


# ── run ──────────────────────────────────────────────────────────────────────
def run_variation(name, items, endpoint, model, keep_alive, timeout):
    system, wrap = recipes.VARIATIONS[name]
    scores = []
    for idx, item in enumerate(items, 1):
        user = wrap(item["prompt"])
        t0 = time.monotonic()
        try:
            text = classify(endpoint, model, system, user, keep_alive, timeout)
        except (urllib.error.URLError, TimeoutError) as err:
            print(f"  ! {item['id']}: request failed: {err}", file=sys.stderr)
            text = ""
        dt = time.monotonic() - t0
        pick = parse_pick(text)
        sc = score_item(item, pick)
        sc["latency_s"] = round(dt, 2)
        sc["raw"] = text.strip()
        scores.append(sc)
        flag = "ok" if sc["model_match"] and sc["thinking_match"] else "  "
        print(
            f"  [{idx:2}/{len(items)}] {flag} {item['id']:26} "
            f"op={sc['exp_model']}/{sc['exp_thinking']:7} "
            f"pred={str(sc['pred_model']):6}/{str(sc['pred_thinking']):7} "
            f"adv={str(sc['pred_advisor']):6} {sc['latency_s']:5}s"
        )
    return scores


def pct(x):
    return f"{100 * x:4.0f}%"


def print_summary_table(results):
    print("\n" + "=" * 78)
    print("SUMMARY — picks vs the operator's actual settings")
    print("=" * 78)
    hdr = f"{'variation':18} {'parse':>6} {'model':>6} {'think':>6} {'exact':>6} {'over':>5} {'under':>5} {'elite':>6} {'Δthink':>7}"
    print(hdr)
    print("-" * len(hdr))
    for name, summ in results.items():
        er = "n/a" if summ["elite_recall"] is None else pct(summ["elite_recall"])
        print(
            f"{name:18} {pct(summ['parse_rate']):>6} {pct(summ['model_acc']):>6} {pct(summ['thinking_acc']):>6} "
            f"{pct(summ['exact_acc']):>6} {summ['over_provision']:>5} {summ['under_provision']:>5} "
            f"{er:>6} {summ['mean_thinking_dist']:>7.2f}"
        )
    print(
        "\nparse = share of replies with a usable JSON object (an unparsed reply is a "
        "miss — the picker gets no suggestion).\nmodel/think/exact = share of ALL "
        "items (unparsed counted as a miss) where the pick matched the operator's "
        "model tier / thinking level / both.\nover,under = of the items it answered, "
        "how many it sized above/below the operator on the thinking ladder.\nelite = "
        "recall of the fable/critical tier on the items where the operator chose it.\n"
        "Δthink = mean ladder distance on thinking, over answered items (0 = perfect)."
        "\nAdvisor is not scored: omp sessions do not record an advisor setting, so "
        "there is no ground truth for it."
    )


def write_report(path, results, per_item, model, endpoint):
    lines = [
        "# code prompt→profile classifier — divergence report",
        "",
        f"- model: `{model}`  ·  endpoint: `{endpoint}`",
        f"- variations: {', '.join(results)}",
        "",
        "## Summary (picks vs operator's actual settings)",
        "",
        "`parse` = share of replies with usable JSON (unparsed = a miss, no suggestion). "
        "`model`/`think`/`exact` are over ALL items (unparsed counted as a miss). "
        "`over`/`under` and `Δthink` are over answered items only.",
        "",
        "| variation | parse | model | think | exact | over | under | elite recall | Δthink |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for name, s in results.items():
        er = "n/a" if s["elite_recall"] is None else pct(s["elite_recall"])
        lines.append(
            f"| {name} | {pct(s['parse_rate'])} | {pct(s['model_acc'])} | {pct(s['thinking_acc'])} | "
            f"{pct(s['exact_acc'])} | {s['over_provision']} | {s['under_provision']} | "
            f"{er} | {s['mean_thinking_dist']:.2f} |"
        )
    for name, scores in per_item.items():
        lines += ["", f"## {name} — per item", "",
                  "| id | operator | classifier | advisor | match |", "|---|---|---|---|---|"]
        for s in scores:
            match = "✓" if s["model_match"] and s["thinking_match"] else ""
            lines.append(
                f"| {s['id']} | {s['exp_model']}/{s['exp_thinking']} | "
                f"{s['pred_model']}/{s['pred_thinking']} | {s['pred_advisor']} | {match} |"
            )
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--endpoint", default=os.getenv("CODE_OLLAMA_ENDPOINT", "http://127.0.0.1:11434"))
    ap.add_argument("--model", default=os.getenv("CODE_EVAL_MODEL", "qwen2.5:3b"))
    ap.add_argument("--variations", nargs="+", default=list(recipes.VARIATIONS), choices=list(recipes.VARIATIONS))
    ap.add_argument("--dataset", default=os.path.join(HERE, "dataset.json"))
    ap.add_argument("--limit", type=int, default=0, help="only the first N items (0 = all)")
    ap.add_argument("--keep-alive", default="5m", help="how long ollama holds the model resident between calls")
    ap.add_argument("--timeout", type=float, default=180.0, help="per-request timeout (s)")
    ap.add_argument("--report", default=os.path.join(HERE, "report.md"), help="markdown report path (gitignored)")
    ap.add_argument("--json-out", default=os.path.join(HERE, "report.json"), help="raw results JSON (gitignored)")
    args = ap.parse_args()

    items = json.load(open(args.dataset, encoding="utf-8"))["items"]
    if args.limit:
        items = items[: args.limit]

    # Fail early and clearly if the daemon is down — the whole point is a live run.
    try:
        with urllib.request.urlopen(args.endpoint + "/api/version", timeout=5) as r:
            ver = json.load(r).get("version", "?")
    except (urllib.error.URLError, TimeoutError) as err:
        print(f"ollama not reachable at {args.endpoint} ({err}).\n"
              f"Start it first: `systemctl --user start ollama` or `ollama serve &`.", file=sys.stderr)
        return 2
    print(f"ollama {ver} @ {args.endpoint} · model {args.model} · {len(items)} items · "
          f"{len(args.variations)} variation(s)")

    results, per_item = {}, {}
    for name in args.variations:
        print(f"\n── variation: {name} " + "─" * (60 - len(name)))
        scores = run_variation(name, items, args.endpoint, args.model, args.keep_alive, args.timeout)
        per_item[name] = scores
        results[name] = summarize(scores)

    print_summary_table(results)
    write_report(args.report, results, per_item, args.model, args.endpoint)
    json.dump({"model": args.model, "results": results, "per_item": per_item},
              open(args.json_out, "w", encoding="utf-8"), indent=1)
    print(f"\nwrote {args.report} and {args.json_out} (both gitignored)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

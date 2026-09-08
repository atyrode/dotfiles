#!/usr/bin/env python3
"""Offline refresh and scheduled-freshness regressions; no OMP/provider calls.

Usage: python3 ci/check-model-facts.py REFRESH_SCRIPT FRESHNESS_WORKFLOW
"""
import contextlib
import copy
import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from ruamel.yaml import YAML

REFRESH_SCRIPT, WORKFLOW = map(Path, sys.argv[1:3])
del sys.argv[1:3]
spec = importlib.util.spec_from_file_location("refresh_model_facts", REFRESH_SCRIPT)
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)
workflow = YAML(typ="safe").load(WORKFLOW.read_text())
freshness_script = next(step["run"] for step in workflow["jobs"]["check"]["steps"] if step.get("id") == "freshness")

CATALOG = """# Retain the operator's curated catalog and comments.
refreshed: '2000-01-01'
probed: true
models:
  alpha:
    id: fixture-alpha
    pool: O
    tier: 1
    bucket: fixture
    cost_in: 1
    cost_out: 2
    context: 100
    thinking: low→high
    speed: 10
    ttft: 9
    role: curated alpha # keep this note
  beta:
    id: fixture-beta
    pool: O
    tier: 2
    bucket: fixture
    cost_in: 3
    cost_out: 4
    context: 200
    thinking: low→high
    speed: 20
    ttft: 8
    role: curated beta
"""


def metadata():
    return {"models": [
        {"provider": "openai-codex", "id": f"fixture-{key}", "cost": {"input": 5, "output": 6},
         "contextWindow": 1000, "thinking": ["min", "max"], "reasoning": True}
        for key in ("alpha", "beta")
    ]}


def benchmark():
    return {"profile": "chat", "runs": 2, "maxTokens": 256, "failures": 0, "models": [
        {"selector": f"openai-codex/fixture-{key}", "model": f"openai-codex/fixture-{key}",
         "results": [{"ok": True, "challenge": "chat", "tokensPerSecond": 30, "ttftMs": 1250},
                     {"ok": True, "challenge": "chat", "tokensPerSecond": 50, "ttftMs": 1750}],
         "stats": {"tokensPerSecond": {"mean": 40}, "ttftMs": {"mean": 1500}},
         "byChallenge": {}}
        for key in ("alpha", "beta")
    ]}


class RefreshFacts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="model-facts-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / "models.yml"
        self.path.write_text(CATALOG)
        self.calls = []

    def run_refresh(self, *, meta=None, bench=None, exit_code=0, skip=False, saved=False):
        meta = metadata() if meta is None else meta
        bench = benchmark() if bench is None else bench

        def command(argv, **kwargs):
            self.calls.append(argv)
            if argv[1] == "models":
                output = meta if isinstance(meta, str) else json.dumps(meta)
                return subprocess.CompletedProcess(argv, 0, output, "")
            if argv[1] == "bench":
                self.assertIn("--profile", argv)
                self.assertEqual(argv[argv.index("--profile") + 1], "chat")
                output = bench if isinstance(bench, str) else json.dumps(bench)
                return subprocess.CompletedProcess(argv, exit_code, output, "")
            self.fail("unexpected external command")

        argv = [str(REFRESH_SCRIPT), "--file", str(self.path)]
        if skip:
            argv.append("--skip-bench")
        if saved:
            source = self.root / "bench.json"
            source.write_text(bench if isinstance(bench, str) else json.dumps(bench))
            argv.extend(["--bench-json", str(source)])
        output = io.StringIO()
        with patch.object(sys, "argv", argv), patch.object(refresh.subprocess, "run", command), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            status = refresh.main()
        self.report = output.getvalue()
        self.doc = YAML(typ="safe").load(self.path.read_text())
        return status

    def assert_stale(self):
        self.assertEqual(self.doc["refreshed"], "2000-01-01")
        self.assertIn("unchanged", self.report)

    def test_complete_refresh_advances_only_after_all_facts(self):
        self.assertEqual(self.run_refresh(), 0)
        self.assertEqual(self.doc["refreshed"], datetime.date.today().isoformat())
        self.assertEqual(self.doc["models"]["alpha"]["speed"], 40)
        self.assertEqual(self.doc["models"]["beta"]["ttft"], 1.5)
        self.assertEqual(self.doc["models"]["alpha"]["thinking"], "min→max")
        self.assertTrue(self.doc["probed"])
        self.assertEqual(self.doc["models"]["beta"]["role"], "curated beta")
        self.assertIn("# keep this note", self.path.read_text())

    def test_skip_updates_metadata_without_benchmark_or_freshness(self):
        self.assertEqual(self.run_refresh(skip=True), 0)
        self.assert_stale()
        self.assertEqual([call[1] for call in self.calls], ["models"])
        self.assertEqual(self.doc["models"]["alpha"]["cost_in"], 5)
        self.assertEqual(self.doc["models"]["alpha"]["speed"], 10)
        self.assertEqual(self.doc["models"]["alpha"]["ttft"], 9)

    def test_partial_metadata_retains_missing_fields_not_valid_neighbors(self):
        meta = metadata()
        meta["models"][0].update(cost={"input": 0, "output": 7}, contextWindow=None, thinking=[])
        meta["models"].pop()
        self.assertEqual(self.run_refresh(meta=meta), 1)
        self.assert_stale()
        alpha = self.doc["models"]["alpha"]
        self.assertEqual((alpha["cost_in"], alpha["cost_out"], alpha["context"], alpha["thinking"]), (1, 7, 100, "low→high"))
        self.assertEqual(alpha["speed"], 40)
        self.assertEqual(self.doc["models"]["beta"]["context"], 200)

    def test_reseller_price_can_complete_unpriced_metadata(self):
        meta = metadata()
        meta["models"][0]["cost"] = {"input": 0, "output": 0}
        sibling = copy.deepcopy(meta["models"][0])
        sibling.update(provider="fixture-reseller", id="vendor/fixture-alpha", cost={"input": 8, "output": 9})
        meta["models"].append(sibling)
        self.assertEqual(self.run_refresh(meta=meta), 0)
        self.assertEqual(self.doc["models"]["alpha"]["cost_in"], 8)

    def test_nonzero_bench_stdout_keeps_successful_other_models(self):
        bench = benchmark()
        bench["models"][0]["results"][1] = {"ok": False, "challenge": "chat", "error": "fixture failure"}
        bench["failures"] = 1
        self.assertEqual(self.run_refresh(bench=bench, exit_code=1), 1)
        self.assert_stale()
        self.assertEqual(self.doc["models"]["alpha"]["speed"], 10)
        self.assertEqual(self.doc["models"]["alpha"]["ttft"], 9)
        self.assertEqual(self.doc["models"]["beta"]["speed"], 40)

    def test_missing_benchmark_does_not_certify_entire_catalog(self):
        bench = benchmark()
        bench["models"].pop()
        self.assertEqual(self.run_refresh(bench=bench, saved=True), 1)
        self.assert_stale()
        self.assertEqual(self.doc["models"]["alpha"]["speed"], 40)
        self.assertEqual(self.doc["models"]["beta"]["speed"], 20)

    def test_bad_metric_retains_only_that_value(self):
        bench = benchmark()
        bench["models"][0]["stats"]["ttftMs"]["mean"] = float("nan")
        self.assertEqual(self.run_refresh(bench=bench), 1)
        self.assert_stale()
        self.assertEqual(self.doc["models"]["alpha"]["speed"], 40)
        self.assertEqual(self.doc["models"]["alpha"]["ttft"], 9)

    def test_invalid_measurements_cannot_hide_behind_valid_aggregate(self):
        bench = benchmark()
        bench["models"][0]["results"][0]["tokensPerSecond"] = True
        bench["models"][1]["results"].pop()
        self.assertEqual(self.run_refresh(bench=bench), 1)
        self.assert_stale()
        self.assertEqual(self.doc["models"]["alpha"]["speed"], 10)
        self.assertEqual(self.doc["models"]["beta"]["speed"], 20)

    def test_malformed_benchmark_preserves_measurements_and_saves_metadata(self):
        self.assertEqual(self.run_refresh(bench="{truncated"), 1)
        self.assert_stale()
        self.assertEqual(self.doc["models"]["alpha"]["context"], 1000)
        self.assertEqual(self.doc["models"]["alpha"]["speed"], 10)

    def test_wrong_workload_cannot_certify_chat_facts(self):
        bench = benchmark()
        bench["profile"] = "mix"
        self.assertEqual(self.run_refresh(bench=bench, saved=True), 1)
        self.assert_stale()
        self.assertEqual(self.doc["models"]["alpha"]["speed"], 10)

    def test_malformed_metadata_aborts_without_rewrite_or_paid_calls(self):
        self.assertEqual(self.run_refresh(meta={"models": {}}), 1)
        self.assertEqual(self.path.read_text(), CATALOG)
        self.assertEqual([call[1] for call in self.calls], ["models"])

    def test_saved_complete_benchmark_can_attest_refresh(self):
        self.path.write_text(CATALOG.replace("'2000-01-01'", "null"))
        self.assertEqual(self.run_refresh(saved=True), 0)
        self.assertEqual(self.doc["refreshed"], datetime.date.today().isoformat())
        self.assertEqual([call[1] for call in self.calls], ["models"])

    def test_workflow_distinguishes_unknown_old_current_and_invalid_dates(self):
        catalog = self.root / "pkgs/omp-configured/config/models.yml"
        catalog.parent.mkdir(parents=True)
        output = self.root / "outputs"
        today = datetime.date.today()
        cases = [("null", "unknown"), ("", "unknown"), ("'2000-01-01'", str((today - datetime.date(2000, 1, 1)).days)),
                 (json.dumps(today.isoformat()), "0"), ("'2026-02-30'", None),
                 (json.dumps((today + datetime.timedelta(days=1)).isoformat()), None),
                 ("nonsense", None), ("null\nrefreshed: null", None)]
        for stamp, age in cases:
            with self.subTest(stamp=stamp):
                catalog.write_text(f"refreshed: {stamp}\nmodels: {{}}\n")
                output.write_text("")
                result = subprocess.run([sys.executable, "-c", freshness_script], cwd=self.root,
                                        env={**os.environ, "GITHUB_OUTPUT": str(output)}, capture_output=True, text=True)
                if age is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(output.read_text(), "")
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"age={age}\n", output.read_text())


if __name__ == "__main__":
    unittest.main()

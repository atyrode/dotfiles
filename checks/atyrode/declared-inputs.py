"""Exercise declaration migration and placement without any live Clan store."""

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("inputs", sys.argv.pop(1))
spec = importlib.util.spec_from_loader(loader.name, loader)
inputs = importlib.util.module_from_spec(spec)
loader.exec_module(inputs)


class Readiness(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "placed"
        self.target.write_text("fixture-only")
        self.source = self.root / "hm-source"
        self.source.symlink_to(self.target)
        self.link = self.root / "managed-link"
        self.link.symlink_to(self.source)
        self.clan = self.root / "clan"
        self.clan.write_text(
            f"#!{sys.executable}\n"
            "from pathlib import Path\n"
            "import sys\n"
            "assert sys.argv[1:] == ['vars', 'check', 'fixture', '--flake', '.']\n"
            "state = Path(__file__).with_name('clan-state').read_text()\n"
            "print(state)\n"
            "sys.exit(bool(state))\n"
        )
        self.clan.chmod(0o755)
        self.state = self.root / "clan-state"
        self.state.write_text("")
        self.manifest = {
            "schemaVersion": 2, "host": "fixture", "flake": ".",
            "generators": [{"name": "archive", "files": [{"name": "old", "path": str(self.target), "access": None}]}],
            "links": [{"link": str(self.link), "source": str(self.source)}],
        }

    def probe(self, sources_only=False):
        return inputs.readiness(self.manifest, str(self.clan), sources_only=sources_only)

    def test_new_required_undeployed_file_is_named_until_generated(self):
        self.assertTrue(self.probe()["ready"])
        self.manifest["generators"][0]["files"].append({"name": "new-input", "path": None, "access": None})
        self.state.write_text("Secret var 'new-input' for service 'archive' in machine fixture is missing.")
        result = self.probe()
        self.assertIn({"code": "generation-required", "subject": "archive/new-input"}, result["findings"])
        self.assertFalse(self.probe(sources_only=True)["ready"])
        # Source generation clears an input that is deliberately not deployed.
        self.state.write_text("")
        self.assertTrue(self.probe()["ready"])

    def test_source_generation_does_not_hide_unplaced_new_output(self):
        new = self.root / "new-output"
        self.manifest["generators"][0]["files"].append({"name": "new-output", "path": str(new), "access": None})
        self.assertTrue(self.probe(sources_only=True)["ready"])
        self.assertTrue(any(f["subject"] == "archive/new-output" and f["code"] == "absent" for f in self.probe()["findings"]))
        new.write_text("fixture-only")
        self.assertTrue(self.probe()["ready"])

    def test_dangling_link_names_link_and_target_then_recovers(self):
        self.target.unlink()
        findings = self.probe()["findings"]
        self.assertIn({"code": "absent", "subject": "managed link", "path": str(self.link), "target": str(self.target)}, findings)
        self.target.write_text("restored")
        self.assertTrue(self.probe()["ready"])

    def test_permission_failure_is_not_absence(self):
        with patch.object(inputs.Path, "resolve", side_effect=PermissionError()):
            findings = self.probe()["findings"]
        self.assertTrue(findings)
        self.assertTrue(all(f["code"] == "inspection-unavailable" for f in findings))
        with patch.object(inputs.os, "access", return_value=False):
            self.assertEqual(inputs.inspect_path(self.target)[0], "permission-unknown")
        self.assertTrue(self.probe()["ready"])

    def test_root_consumer_does_not_require_operator_read_access(self):
        self.target.chmod(0o400)
        metadata = list(self.target.stat())
        metadata[4:6] = [0, 0]
        file = {"path": str(self.source), "access": {"owner": "0", "group": "0", "mode": "0400"}}
        with patch.object(inputs, "input_metadata", return_value=(self.target, os.stat_result(metadata))), \
             patch.object(inputs.os, "access", return_value=False):
            self.assertEqual(inputs.inspect_input(file)[0], "ok")
        file["access"]["mode"] = "0600"
        with patch.object(inputs, "input_metadata", return_value=(self.target, os.stat_result(metadata))):
            self.assertEqual(inputs.inspect_input(file)[0], "placement-required")

    def test_consumer_ownership_mode_and_file_kind_are_enforced(self):
        self.target.chmod(0o400)
        file = self.manifest["generators"][0]["files"][0]
        file["access"] = {"owner": str(os.getuid()), "group": str(self.target.stat().st_gid), "mode": "0400"}
        self.assertTrue(self.probe()["ready"])
        self.target.chmod(0o644)
        self.assertEqual(self.probe()["findings"][0]["code"], "placement-required")
        self.target.unlink()
        self.target.mkdir()
        self.assertEqual(self.probe()["findings"][0]["code"], "placement-required")

    def test_denied_secret_metadata_is_not_a_missing_key(self):
        file = {"path": str(self.source), "access": {"owner": "0", "group": "0", "mode": "0400"}}
        with patch.object(inputs, "input_metadata", side_effect=PermissionError()):
            self.assertEqual(inputs.inspect_input(file)[0], "inspection-unavailable")
        with patch.object(inputs, "input_metadata", side_effect=FileNotFoundError()):
            self.assertEqual(inputs.inspect_input(file)[0], "absent")

    def test_bad_consumer_metadata_is_rejected_before_source_checks(self):
        self.manifest["generators"][0]["files"][0]["access"] = {"owner": "root", "group": "root", "mode": "not-a-mode"}
        with patch.object(inputs, "source_findings") as sources:
            with self.assertRaises(ValueError):
                self.probe()
            sources.assert_not_called()

    def test_upstream_invalidation_and_unavailable_are_distinct(self):
        self.state.write_text("Generator 'archive' in machine fixture has outdated invalidation hash.")
        self.assertIn({"code": "generation-required", "subject": "archive"}, self.probe()["findings"])
        self.state.write_text("permission denied: DO-NOT-EXPOSE")
        result = self.probe()
        self.assertEqual(result["findings"][0]["code"], "inspection-unavailable")
        self.assertNotIn("DO-NOT-EXPOSE", json.dumps(result))
        self.state.write_text("")
        self.assertTrue(self.probe()["ready"])


unittest.main()

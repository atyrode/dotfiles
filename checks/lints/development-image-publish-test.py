#!/usr/bin/env python3
"""Exercise development image publication against an offline registry and Docker."""

import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[2] / "ci/publish-development-image.py"
)
SPEC = importlib.util.spec_from_file_location("publish_development_image", SCRIPT)
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)
REVISION = "b" * 40
# Publication keeps Docker state under /dev/shm, which not every check builder has.
TEMPORARY_DIRECTORY = tempfile.TemporaryDirectory


def labels():
    return {
        "org.opencontainers.image.revision": REVISION,
        "org.opencontainers.image.source": publisher.SOURCE,
    }


class LaggingRegistry:
    """Serves pushed references only after `lag` reads, as the registry did."""

    def __init__(self, lag):
        self.lag = lag
        self.store = {}
        self.pushes = []

    def push(self, reference, manifest):
        payload = json.dumps(manifest, sort_keys=True).encode()
        digest = "sha256:" + hashlib.sha256(payload).hexdigest()
        self.pushes.append(reference)
        entry = [manifest, digest, self.lag]
        for key in (reference, digest):
            self.store[key] = entry
        return digest

    def client(self, *_credentials):
        registry = self

        class Client:
            def authenticate(self):
                pass

            def manifest(self, reference):
                entry = registry.store.get(reference)
                if entry is None:
                    return None
                if entry[2] > 0:
                    entry[2] -= 1
                    return None
                return entry[0], entry[1]

        return Client()


class FakeDocker:
    def __init__(self, registry, archives):
        self.registry = registry
        self.archives = archives
        self.loaded = None
        self.platforms = {}

    def __call__(self, args, _environment, *, stdin=None, timeout=900):
        verb = args[1:3]
        if verb[0] == "load":
            self.loaded = Path(args[-1]).parent.name.removeprefix("development-image-")
        elif verb == ["image", "inspect"]:
            return json.dumps([{"Id": f"id-{self.loaded}", "Os": "linux",
                                "Architecture": self.loaded, "Config": {"Labels": labels()}}])
        elif verb[0] == "push":
            architecture = args[2].rsplit("-", 1)[1]
            digest = self.registry.push(args[2].split(":", 1)[1],
                                        {"config": {"digest": self.archives[architecture]}})
            self.platforms[architecture] = digest
        elif verb == ["manifest", "push"]:
            self.registry.push(args[3].split(":", 1)[1], {"manifests": [
                {"platform": {"os": "linux", "architecture": architecture}, "digest": digest}
                for architecture, digest in self.platforms.items()
            ]})
        return ""


class PublishVisibilityTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.config_digests = {}
        for architecture in ("amd64", "arm64"):
            config = json.dumps({"os": "linux", "architecture": architecture,
                                 "config": {"Labels": labels()}}).encode()
            self.config_digests[architecture] = "sha256:" + hashlib.sha256(config).hexdigest()
            manifest = json.dumps([{"RepoTags": [f"{publisher.IMAGE}:{REVISION}"],
                                    "Config": "config.json"}]).encode()
            directory = self.root / f"development-image-{architecture}"
            directory.mkdir()
            with tarfile.open(directory / "development-image.tar.gz", "w:gz") as archive:
                for name, payload in (("manifest.json", manifest), ("config.json", config)):
                    member = tarfile.TarInfo(name)
                    member.size = len(payload)
                    archive.addfile(member, io.BytesIO(payload))
        self.args = argparse.Namespace(archives=self.root, revision=REVISION, username="ci",
                                       output=self.root / "reference.txt")

    def publish(self, lag):
        registry = LaggingRegistry(lag)
        docker = FakeDocker(registry, self.config_digests)
        sleeps = []
        anonymous = subprocess.CompletedProcess([], 0, "", "")
        with patch.object(publisher, "Registry", registry.client), \
                patch.object(publisher, "command", docker), \
                patch.object(publisher.subprocess, "run", return_value=anonymous), \
                patch.object(time, "sleep", sleeps.append), \
                patch.object(publisher.tempfile, "TemporaryDirectory",
                             lambda **_: TEMPORARY_DIRECTORY()), \
                patch.dict(os.environ, {}, clear=False) as environment:
            environment.pop("GITHUB_STEP_SUMMARY", None)
            try:
                publisher.publish(self.args, "token", {})
                error = None
            except publisher.PublicationError as raised:
                error = raised
        return registry, sleeps, error

    def test_lagging_reads_after_each_push_still_publish_once(self):
        registry, sleeps, error = self.publish(lag=2)
        self.assertIsNone(error)
        self.assertEqual(registry.pushes, [f"{REVISION}-amd64", f"{REVISION}-arm64", REVISION])
        self.assertEqual(sleeps, [2, 4] * 3)
        index_digest = registry.store[REVISION][1]
        self.assertEqual(self.args.output.read_text(), f"{publisher.IMAGE}@{index_digest}\n")

    def test_reference_that_never_appears_fails_without_pushing_again(self):
        registry, sleeps, error = self.publish(lag=100)
        self.assertEqual(str(error), "Published platform manifest is missing")
        self.assertEqual(registry.pushes, [f"{REVISION}-amd64"])
        self.assertEqual(sleeps, list(publisher.VISIBILITY_DELAYS))


if __name__ == "__main__":
    unittest.main()

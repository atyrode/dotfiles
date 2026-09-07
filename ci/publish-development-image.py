#!/usr/bin/env python3
"""Publish the two tested archives; registry credentials arrive only on stdin."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request


IMAGE = "ghcr.io/atyrode/development"
REPOSITORY = "atyrode/development"
SOURCE = "https://github.com/atyrode/dotfiles"
ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)


class PublicationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PublicationError(message)


def command(args, environment, *, stdin=None, timeout=900):
    # Docker errors may contain credential-bearing server responses. Never echo them.
    try:
        result = subprocess.run(
            args, input=stdin, text=True, capture_output=True, env=environment,
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise PublicationError(f"{args[0]} operation could not complete") from None
    require(result.returncode == 0, f"{args[0]} {args[1]} failed; output withheld to protect credentials")
    return result.stdout


class Registry:
    def __init__(self, username=None, password=None):
        self.authorization = None
        self.username = username
        self.password = password

    def authenticate(self):
        request = urllib.request.Request(
            "https://ghcr.io/token?service=ghcr.io&scope=repository:atyrode/development:pull"
        )
        if self.password is not None:
            basic = base64.b64encode(f"{self.username}:{self.password}".encode()).decode()
            request.add_header("Authorization", f"Basic {basic}")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                token = json.load(response)["token"]
            self.authorization = f"Bearer {token}"
        except (OSError, ValueError, KeyError):
            raise PublicationError("Registry authentication failed; response withheld") from None

    def manifest(self, reference):
        for attempt in range(2):
            request = urllib.request.Request(
                f"https://ghcr.io/v2/{REPOSITORY}/manifests/{reference}",
                headers={"Accept": ACCEPT},
            )
            if self.authorization:
                request.add_header("Authorization", self.authorization)
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    payload = response.read()
                    digest = "sha256:" + hashlib.sha256(payload).hexdigest()
                    advertised = response.headers.get("Docker-Content-Digest")
                require(advertised == digest, "Registry manifest digest does not match its bytes")
                return json.loads(payload), digest
            except urllib.error.HTTPError as error:
                if error.code == 401 and attempt == 0:
                    self.authenticate()
                    continue
                if error.code == 404:
                    return None
                raise PublicationError(f"Registry manifest request failed with HTTP {error.code}; not absence") from None
            except (OSError, ValueError):
                raise PublicationError("Registry manifest request failed; not absence") from None
        raise PublicationError("Registry authentication did not authorize manifest access")


def archive_config(path, revision, architecture):
    with tarfile.open(path, "r:*") as archive:
        member = archive.extractfile("manifest.json")
        require(member is not None, "Archive is missing manifest.json")
        entries = json.load(member)
        require(isinstance(entries, list) and len(entries) == 1, "Archive must contain exactly one image")
        entry = entries[0]
        require(entry.get("RepoTags") == [f"{IMAGE}:{revision}"], "Archive tag differs from the tested revision")
        member = archive.extractfile(entry["Config"])
        require(member is not None, "Archive is missing its config member")
        payload = member.read()
    config = json.loads(payload)
    verify_config(config, revision, architecture)
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def verify_config(config, revision, architecture, *, loaded=False):
    require(config.get("Os" if loaded else "os") == "linux", "Image OS is not Linux")
    require(config.get("Architecture" if loaded else "architecture") == architecture, "Image architecture mismatch")
    labels = config.get("Config" if loaded else "config", {}).get("Labels", {}) or {}
    require(labels.get("org.opencontainers.image.revision") == revision, "Image revision label mismatch")
    require(labels.get("org.opencontainers.image.source") == SOURCE, "Image source label mismatch")


def verify_platform(manifest, config_digest):
    require("manifests" not in manifest, "Platform tag unexpectedly contains an index")
    require(manifest.get("config", {}).get("digest") == config_digest,
            "Immutable platform tag exists with a different archive config digest; refusing overwrite")


def verify_index(manifest, platforms):
    entries = manifest.get("manifests", [])
    actual = []
    for entry in entries:
        platform = entry.get("platform", {})
        actual.append((platform.get("os"), platform.get("architecture"), entry.get("digest")))
    expected = [("linux", arch, digest) for arch, digest in platforms.items()]
    require(len(actual) == 2 and sorted(actual) == sorted(expected),
            "Immutable index does not match the two verified platform digests; refusing overwrite")


def publish(args, password, environment):
    registry = Registry(args.username, password)
    command(["docker", "login", "ghcr.io", "--username", args.username, "--password-stdin"],
            environment, stdin=password + "\n", timeout=60)
    registry.authenticate()
    platforms = {}
    loaded_ids = set()
    for architecture in ("amd64", "arm64"):
        archive = args.archives / f"development-image-{architecture}" / "development-image.tar.gz"
        require(archive.is_file(), f"Missing tested {architecture} archive")
        config_digest = archive_config(archive, args.revision, architecture)
        print(f"Loading tested linux/{architecture} archive", flush=True)
        command(["docker", "load", "--input", str(archive)], environment)
        # Both archives carry the same tag. Capture and use the ID before the next load.
        loaded = json.loads(command(["docker", "image", "inspect", f"{IMAGE}:{args.revision}"], environment))[0]
        image_id = loaded["Id"]
        loaded_ids.add(image_id)
        verify_config(loaded, args.revision, architecture, loaded=True)
        tag = f"{args.revision}-{architecture}"
        existing = registry.manifest(tag)
        if existing is None:
            print(f"Publishing tested linux/{architecture} revision", flush=True)
            command(["docker", "tag", image_id, f"{IMAGE}:{tag}"], environment)
            command(["docker", "push", f"{IMAGE}:{tag}"], environment)
            existing = registry.manifest(tag)
            require(existing is not None, "Published platform manifest is missing")
        else:
            print(f"Reusing immutable linux/{architecture} revision", flush=True)
        verify_platform(existing[0], config_digest)
        platforms[architecture] = existing[1]

    existing = registry.manifest(args.revision)
    if existing is None:
        reference = f"{IMAGE}:{args.revision}"
        print("Publishing verified multi-platform index", flush=True)
        command(["docker", "manifest", "create", reference,
                 *[f"{IMAGE}@{digest}" for digest in platforms.values()]], environment)
        for architecture, digest in platforms.items():
            command(["docker", "manifest", "annotate", reference, f"{IMAGE}@{digest}",
                     "--os", "linux", "--arch", architecture], environment)
        command(["docker", "manifest", "push", reference], environment)
        existing = registry.manifest(args.revision)
        require(existing is not None, "Published index is missing")
    else:
        print("Reusing immutable multi-platform index", flush=True)
    verify_index(existing[0], platforms)
    reference = f"{IMAGE}@{existing[1]}"
    # The anonymous pull must fetch blobs, not reuse the archives loaded above.
    command(["docker", "image", "rm", "--force", *sorted(loaded_ids)], environment)

    print("Verifying anonymous digest pulls and standalone startup", flush=True)
    try:
        anonymous = Registry().manifest(existing[1])
        require(anonymous is not None and anonymous[1] == existing[1], "Anonymous index is unavailable")
        verify_index(anonymous[0], platforms)
        with tempfile.TemporaryDirectory(prefix="development-anonymous-", dir="/dev/shm") as directory:
            anonymous_env = {**environment, "DOCKER_CONFIG": directory}
            # Pull both platforms from the immutable index, then run the native one.
            for architecture in ("arm64", "amd64"):
                pulled = subprocess.run(
                    ["docker", "pull", "--platform", f"linux/{architecture}",
                     f"{IMAGE}@{platforms[architecture]}" if architecture == "arm64" else reference],
                    env=anonymous_env, text=True, capture_output=True, timeout=900, check=False,
                )
                # This client has no credentials. Preserve Docker's actionable error,
                # excluding registry URLs that may carry signed blob-download queries.
                detail = re.sub(r"https?://\S+", "[registry endpoint]", pulled.stderr[-4000:])
                require(pulled.returncode == 0, f"Anonymous linux/{architecture} pull failed: {detail}")
            container = Path(directory).name
            try:
                command(["docker", "run", "--name", container, "--rm", "--network", "none",
                         "--platform", "linux/amd64", reference, "/bin/bash", "-c",
                         'test "$(id -u):$(id -g)" = 1000:1000 && test "$HOME" = /home/developer && test -x "$HOME/.nix-profile/bin/zsh"'],
                        anonymous_env, timeout=180)
            finally:
                subprocess.run(["docker", "rm", "--force", container], env=anonymous_env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=30, check=False)
    except PublicationError as error:
        raise PublicationError(
            f"Anonymous pull/run proof failed: {error}. If the package is private, set "
            "ghcr.io/atyrode/development public in GitHub package Settings, then rerun publication."
        ) from None
    args.output.write_text(reference + "\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as stream:
            stream.write(f"## Development environment\n\n`{reference}`\n\nVerified linux/amd64 and linux/arm64; anonymous pulls and native standalone startup passed.\n")
    print(reference)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archives", type=Path)
    parser.add_argument("revision")
    parser.add_argument("--username", required=True)
    parser.add_argument("--output", type=Path, default=Path("development-image-reference.txt"))
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{40}", args.revision), "Expected a full main commit SHA")
    password = sys.stdin.read().rstrip("\n")
    require(bool(password), "Missing registry token on stdin")
    os.umask(0o077)
    environment = {key: value for key, value in os.environ.items()
                   if key not in ("GH_TOKEN", "GITHUB_TOKEN", "REGISTRY_TOKEN", "DOCKER_AUTH_CONFIG")}
    # Normal cancellation unwinds the context manager and removes tmpfs credentials.
    def interrupted(signum, _frame):
        raise PublicationError(f"Publication interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    with tempfile.TemporaryDirectory(prefix="development-publish-", dir="/dev/shm") as directory:
        os.chmod(directory, 0o700)
        publish(args, password, {**environment, "DOCKER_CONFIG": directory})


if __name__ == "__main__":
    try:
        main()
    except (PublicationError, OSError, ValueError, KeyError, TypeError, IndexError,
            tarfile.TarError, subprocess.TimeoutExpired) as error:
        message = str(error) if isinstance(error, PublicationError) else "Malformed archive or publication response; details withheld"
        print(f"development-image: {message}", file=sys.stderr)
        sys.exit(1)

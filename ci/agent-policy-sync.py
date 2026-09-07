#!/usr/bin/env python3
"""Converge the three enrolled repositories using their own Actions token.

Only the checked-out, reviewed dotfiles helper is executed. Historical PR metadata
selects data to reconstruct, never commands or executable historical helpers.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time


SOURCE_REPO = "atyrode/dotfiles"
SOURCE_PATH = "modules/home/agents/engineering.md"
SOURCE_URL = f"https://github.com/{SOURCE_REPO}/blob/main/{SOURCE_PATH}"
BRANCH = "bot/agent-policy"
TITLE = "chore(policy): synchronize shared engineering contract"
BOT = "github-actions[bot]"
REQUIRED = {
    "atyrode/code": ("test",),
    "atyrode/babel": ("test", "race", "web", "browser"),
    "atyrode/manifold": ("gate",),
}
SHA = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
META = "agent-policy-sync:v1"
STATUS = "agent-policy-sync-status:v1"
POLL_SECONDS = 10
OVERALL_SECONDS = 90 * 60
DISCOVERY_SECONDS = 5 * 60
PR_SECONDS = 60 * 60
MAIN_SECONDS = 20 * 60


class Blocked(Exception):
    """A safe, fixed diagnostic; remote command output is never exposed."""


class Invalid(Blocked):
    pass


def require(condition, message):
    if not condition:
        raise Blocked(message)


def object_id(value, label="object ID"):
    require(isinstance(value, str) and SHA.fullmatch(value), f"invalid {label}")
    return value


def number(value, label="API identifier"):
    require(isinstance(value, int) and not isinstance(value, bool) and value > 0,
            f"invalid {label}")
    return value


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def instant(value):
    require(isinstance(value, str), "invalid timestamp")
    try:
        result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise Blocked("invalid timestamp") from None
    require(result.tzinfo is not None, "timestamp lacks timezone")
    return result


def tagged(body, marker):
    require(isinstance(body, str), "missing owned metadata")
    prefix = f"<!-- {marker} "
    require(body.count(prefix) == 1, "missing or ambiguous owned metadata")
    lines = [line for line in body.splitlines() if line.startswith(prefix)]
    require(len(lines) == 1 and lines[0].endswith(" -->"), "malformed owned metadata")
    try:
        value = json.loads(lines[0][len(prefix):-4])
    except (ValueError, TypeError):
        raise Blocked("malformed owned metadata") from None
    require(isinstance(value, dict), "malformed owned metadata")
    return value


def metadata(pr):
    value = tagged(pr.get("body"), META)
    require(set(value) == {"base", "source", "digest"}, "unexpected PR metadata fields")
    object_id(value["base"], "recorded base")
    object_id(value["source"], "recorded source")
    require(isinstance(value["digest"], str) and DIGEST.fullmatch(value["digest"]),
            "invalid recorded digest")
    return value


def regular_path(path, directory=False):
    """Refuse symlinks in the supplied path, including its ancestors."""
    path = Path(os.path.abspath(path))
    for parent in reversed((path, *path.parents)):
        info = parent.lstat()
        require(not stat.S_ISLNK(info.st_mode), "symlink path refused")
    info = path.stat()
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
            "nonregular path refused")
    return path


class Sync:
    def __init__(self, args):
        self.repository = args.repository
        self.source = Path(os.path.abspath(args.source_checkout))
        self.work = Path(os.path.abspath(args.work_dir))
        self.checkout = self.work / "consumer"
        self.checkout_owned = False
        self.started = time.monotonic()
        self.deadline = self.started + OVERALL_SECONDS
        self.limit = self.deadline
        self.phase = "invocation"
        self.pr = None
        self.pr_owned = False
        self.status = None
        self.status_id = None
        self.source_sha = None
        self.digest = None
        self.head = None
        self.main = None
        self.source_bytes = None
        self.workflow_ids = {}
        self.pr_runs = []
        self.pr_attempts = {}
        self.integration = None
        self.env = os.environ.copy()
        # Ignore ambient Git configuration, hooks, signing and credential stores.
        # The fixed helper reads GH_TOKEN from the environment; no token is placed
        # in argv, a remote URL, Git configuration or an artifact.
        for key in list(self.env):
            if key.startswith("GIT_") or key in {"GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_DEBUG"}:
                del self.env[key]
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1",
            "GH_HOST": "github.com", "LC_ALL": "C", "TZ": "UTC",
        })

    def command(self, argv, *, cwd=None, data=None, allowed=(0,), timeout=60, extra_env=None):
        remaining = min(self.deadline, self.limit) - time.monotonic()
        require(remaining > 0, f"{self.phase}: operation deadline exceeded")
        env = self.env if not extra_env else {**self.env, **extra_env}
        try:
            result = subprocess.run(argv, cwd=cwd, input=data, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=env,
                                    timeout=min(timeout, remaining), check=False)
        except subprocess.TimeoutExpired:
            raise Blocked(f"{self.phase}: {Path(argv[0]).name} command timed out") from None
        except OSError:
            raise Blocked(f"{self.phase}: {Path(argv[0]).name} command unavailable") from None
        require(result.returncode in allowed,
                f"{self.phase}: {Path(argv[0]).name} command failed (exit {result.returncode})")
        return result

    def git(self, *args, cwd=None, data=None, allowed=(0,), extra_env=None):
        return self.command([
            "git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
            "-c", "tag.gpgSign=false", *args,
        ], cwd=cwd or self.checkout, data=data, allowed=allowed, extra_env=extra_env,
            timeout=180).stdout

    def api(self, endpoint, method="GET", payload=None):
        argv = ["gh", "api", "--method", method, endpoint]
        data = None
        if payload is not None:
            argv += ["--input", "-"]
            data = json.dumps(payload, separators=(",", ":")).encode()
        raw = self.command(argv, data=data, timeout=45).stdout
        if not raw.strip():
            return None
        try:
            return json.loads(raw)
        except ValueError:
            raise Blocked(f"{self.phase}: invalid GitHub JSON response") from None

    def pages(self, endpoint, key=None):
        rows = []
        for page in range(1, 21):
            sep = "&" if "?" in endpoint else "?"
            value = self.api(f"{endpoint}{sep}per_page=100&page={page}")
            batch = value.get(key) if key and isinstance(value, dict) else value
            require(isinstance(batch, list), "invalid paginated GitHub response")
            rows.extend(batch)
            if len(batch) < 100:
                return rows
        raise Blocked("GitHub pagination exceeded the bounded inspection limit")

    def pause(self):
        remaining = min(self.limit, self.deadline) - time.monotonic()
        require(remaining > 0, f"{self.phase}: observation deadline exceeded")
        time.sleep(min(POLL_SECONDS, remaining))

    def rev(self, ref, cwd=None):
        return object_id(self.git("rev-parse", "--verify", ref, cwd=cwd).decode().strip())

    def ancestor(self, older, newer, cwd=None):
        result = self.command([
            "git", "-c", "core.hooksPath=/dev/null", "merge-base", "--is-ancestor", older, newer,
        ], cwd=cwd or self.checkout, allowed=(0, 1))
        return result.returncode == 0

    def fetch_main(self):
        self.git("fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
        return self.rev("refs/remotes/origin/main")

    def source_data(self, revision):
        object_id(revision, "source revision")
        require(self.ancestor(revision, "refs/remotes/origin/main", cwd=self.source),
                "recorded policy source is not reachable from canonical main")
        return self.git("show", f"{revision}:{SOURCE_PATH}", cwd=self.source)

    def validate_payload(self, payload):
        with tempfile.TemporaryDirectory(prefix="payload-", dir=self.work) as temp:
            path = Path(temp) / "engineering.md"
            path.write_bytes(payload)
            self.command([sys.executable, str(self.source / "ci/agent-policy.py"),
                          "block", "--source", str(path)])
        return hashlib.sha256(payload).hexdigest()

    def initialize(self):
        if self.repository not in REQUIRED:
            raise Invalid("repository is not enrolled")
        if (os.environ.get("GITHUB_REPOSITORY") != self.repository
                or os.environ.get("GITHUB_EVENT_NAME") not in {"schedule", "workflow_dispatch"}
                or os.environ.get("GITHUB_REF") != "refs/heads/main"):
            raise Invalid("synchronization requires an enrolled repository's schedule or main dispatch")
        if not os.environ.get("GH_TOKEN"):
            raise Invalid("GH_TOKEN is required")
        try:
            self.source = regular_path(self.source, directory=True)
            self.work = regular_path(self.work, directory=True)
            require(self.work.stat().st_uid == os.getuid(), "work directory is not run-owned")
            require(not any(self.work.iterdir()), "work directory must be empty")
            require(self.source not in self.work.parents and self.work not in self.source.parents
                    and self.source != self.work, "source and work directories must be disjoint")
            regular_path(self.source / "ci/agent-policy.py")
            regular_path(self.source / SOURCE_PATH)
        except (OSError, Blocked):
            raise Invalid("source/work paths must be regular, disjoint; work directory must be empty and owned") from None
        self.work.chmod(0o700)
        self.phase = "source validation"
        require(not self.git("status", "--porcelain=v1", "--untracked-files=all", cwd=self.source),
                "source checkout is not clean")
        require(self.git("remote", "get-url", "origin", cwd=self.source).decode().strip()
                in {f"https://github.com/{SOURCE_REPO}", f"https://github.com/{SOURCE_REPO}.git"},
                "source checkout origin is not canonical dotfiles")
        self.source_sha = self.rev("HEAD", cwd=self.source)
        expected = os.environ.get("AGENT_POLICY_SOURCE_SHA")
        require(expected is not None and expected == self.source_sha,
                "workflow must supply the exact checked-out source revision")
        self.git("fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main", cwd=self.source)
        self.source_bytes = self.source_data(self.source_sha)
        require((self.source / SOURCE_PATH).read_bytes() == self.source_bytes,
                "source worktree does not match the pinned revision")
        self.digest = self.validate_payload(self.source_bytes)
        info = self.api(f"repos/{self.repository}")
        require(isinstance(info, dict) and info.get("full_name") == self.repository
                and info.get("fork") is False and info.get("default_branch") == "main",
                "repository identity, fork status or default branch refused")
        self.phase = "consumer checkout"
        self.checkout_owned = True
        self.git("clone", "--no-checkout", f"https://github.com/{self.repository}.git", str(self.checkout), cwd=self.work)
        self.main = self.fetch_main()
        self.git("checkout", "--detach", self.main)
        self.git("config", "user.name", BOT)
        self.git("config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")

    def pr_identity(self, pr):
        require(isinstance(pr, dict), "invalid PR response")
        number(pr.get("number"), "PR number")
        require(pr.get("user", {}).get("login") == BOT,
                "foreign author on reserved policy PR")
        require(pr.get("head", {}).get("repo", {}).get("full_name") == self.repository
                and pr.get("base", {}).get("repo", {}).get("full_name") == self.repository
                and pr.get("head", {}).get("ref") == BRANCH
                and pr.get("base", {}).get("ref") == "main",
                "policy PR repository or ref identity refused")
        number(pr["head"]["repo"].get("id"), "head repository ID")
        number(pr["base"]["repo"].get("id"), "base repository ID")
        object_id(pr.get("head", {}).get("sha"), "PR head")
        return metadata(pr)

    def pull(self, pr_number):
        pr = self.api(f"repos/{self.repository}/pulls/{number(pr_number)}")
        self.pr_identity(pr)
        return pr

    def list_pulls(self):
        return self.pages(f"repos/{self.repository}/pulls?state=all&head=atyrode:bot%2Fagent-policy&base=main&sort=created&direction=desc")

    def branch_head(self):
        raw = self.git("ls-remote", "--heads", "origin", f"refs/heads/{BRANCH}").decode().strip()
        if not raw:
            return None
        fields = raw.split()
        require(len(fields) == 2 and fields[1] == f"refs/heads/{BRANCH}",
                "ambiguous reserved branch")
        return object_id(fields[0], "remote branch head")

    def expected_tree(self, base, payload):
        """Construct a complete expected tree without checking out untrusted code."""
        object_id(base, "candidate base")
        mode_entry = self.git("ls-tree", "-z", base, "--", "AGENTS.md")
        parts = mode_entry.rstrip(b"\0").split(b"\t")
        require(len(parts) == 2 and parts[1] == b"AGENTS.md", "base lacks a regular root AGENTS.md")
        entry = parts[0].split()
        require(len(entry) == 3 and entry[0] in {b"100644", b"100755"} and entry[1] == b"blob",
                "base AGENTS.md is not a regular file")
        before = self.git("show", f"{base}:AGENTS.md")
        with tempfile.TemporaryDirectory(prefix="candidate-", dir=self.work) as temp:
            root = Path(temp)
            (root / "AGENTS.md").write_bytes(before)
            source = root / "engineering.md"
            source.write_bytes(payload)
            self.command([sys.executable, str(self.source / "ci/agent-policy.py"), "render",
                          "--source", str(source), "--root", str(root), "--layout", "repository"])
            after = (root / "AGENTS.md").read_bytes()
            blob = object_id(self.git("hash-object", "-w", "--stdin", data=after).decode().strip())
            index_env = {"GIT_INDEX_FILE": str(root / "index")}
            self.git("read-tree", base, extra_env=index_env)
            self.git("update-index", "--add", "--cacheinfo", entry[0].decode(), blob,
                     "AGENTS.md", extra_env=index_env)
            tree = object_id(self.git("write-tree", extra_env=index_env).decode().strip())
        return tree, after, before != after

    def verify_owned(self, pr):
        meta = self.pr_identity(pr)
        require(self.ancestor(meta["base"], self.main), "recorded base is not an ancestor of reviewed main")
        payload = self.source_data(meta["source"])
        require(self.validate_payload(payload) == meta["digest"], "historical source digest does not match metadata")
        self.git("fetch", "--no-tags", "origin", f"refs/pull/{pr['number']}/head")
        head = pr["head"]["sha"]
        require(self.rev("FETCH_HEAD") == head, "PR head raced during ownership inspection")
        tree, _, changed = self.expected_tree(meta["base"], payload)
        require(changed, "owned policy PR does not contain a generated update")
        require(self.rev(f"{head}^{{tree}}") == tree,
                "policy PR complete tree differs from reconstructed generated-only candidate")
        require(self.git("diff", "--name-only", "-z", meta["base"], head) == b"AGENTS.md\0",
                "policy PR changes files outside root AGENTS.md")
        return meta

    def holds(self, pr):
        require(not any(label.get("name") in {"needs-operator", "blocked"}
                        for label in pr.get("labels", [])), "policy PR has a maintainer label hold")
        reviews = self.pages(f"repos/{self.repository}/pulls/{pr['number']}/reviews")
        latest = {}
        for review in sorted(reviews, key=lambda row: number(row.get("id"), "review ID")):
            state = review.get("state")
            if state in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
                login = review.get("user", {}).get("login")
                require(isinstance(login, str), "review lacks an author")
                latest[login] = state
        require("CHANGES_REQUESTED" not in latest.values(), "policy PR has a changes-requested review hold")

    def body(self, meta, evidence=()):
        marker = f"<!-- {META} {json.dumps(meta, sort_keys=True, separators=(',', ':'))} -->"
        lines = [TITLE, "", f"Source: {SOURCE_URL}", f"Source revision: `{meta['source']}`",
                 f"Payload SHA256: `{meta['digest']}`", f"Reviewed base: `{meta['base']}`", "",
                 "Scope: only the intact generated shared-engineering span in root AGENTS.md.",
                 "Local instructions and all other files are preserved. This mechanical maintenance",
                 "follows reviewed dotfiles main, including its trusted automation code.", "",
                 "CI evidence: required current-head PR runs must pass before readiness or merge."]
        lines.extend(f"- https://github.com/{self.repository}/actions/runs/{number(run_id)}/attempts/{self.pr_attempts[run_id]}"
                     for run_id in evidence)
        lines.extend(["", "Merge is not deployment or operational verification; main CI is observed separately.",
                      "A needs-operator/blocked label or current changes-requested review holds this PR.", "", marker])
        return "\n".join(lines) + "\n"

    def graphql(self, query, variables):
        value = self.api("graphql", "POST", {"query": query, "variables": variables})
        require(isinstance(value, dict) and not value.get("errors") and isinstance(value.get("data"), dict),
                "GitHub GraphQL operation failed")
        return value["data"]

    def draft(self, pr, ready=False):
        node = pr.get("node_id")
        require(isinstance(node, str) and node, "PR lacks GraphQL node identity")
        operation = "markPullRequestReadyForReview" if ready else "convertPullRequestToDraft"
        query = f"mutation($id:ID!){{{operation}(input:{{pullRequestId:$id}}){{pullRequest{{id isDraft}}}}}}"
        data = self.graphql(query, {"id": node})
        require(data.get(operation, {}).get("pullRequest", {}).get("isDraft") is (not ready),
                "PR readiness transition was not confirmed")

    def load_status(self, pr):
        self.status = None
        self.status_id = None
        comments = self.pages(f"repos/{self.repository}/issues/{pr['number']}/comments")
        owned = [row for row in comments if row.get("user", {}).get("login") == BOT
                 and f"<!-- {STATUS} " in (row.get("body") or "")]
        require(len(owned) <= 1, "ambiguous owned synchronization status comments")
        if not owned:
            return
        row = owned[0]
        status = tagged(row.get("body"), STATUS)
        allowed = {"version", "head", "source", "digest", "merge", "phase", "outcome",
                   "dispatch_requested_at", "run_id", "run_attempt", "tested_sha", "evidence_after"}
        require(set(status) <= allowed and status.get("version") == 1, "invalid synchronization status schema")
        for key in ("head", "source"):
            object_id(status.get(key), f"status {key}")
        require(DIGEST.fullmatch(status.get("digest", "")), "invalid status digest")
        require(status["head"] == pr["head"]["sha"] and status["source"] == metadata(pr)["source"]
                and status["digest"] == metadata(pr)["digest"], "status belongs to another candidate")
        if "merge" in status:
            require(object_id(status["merge"]) == pr.get("merge_commit_sha"), "status merge does not match merged PR")
        if "run_id" in status:
            number(status["run_id"], "status run ID")
        if "run_attempt" in status:
            number(status["run_attempt"], "status run attempt")
        if "tested_sha" in status:
            object_id(status["tested_sha"])
        for key in ("dispatch_requested_at", "evidence_after"):
            if key in status:
                instant(status[key])
        require(status.get("phase") in {"pr", "main", "complete"}
                and status.get("outcome") in {"pending", "success", "failed"}, "invalid synchronization status state")
        self.status, self.status_id = status, number(row.get("id"), "comment ID")

    def save_status(self):
        require(self.pr_owned and self.pr and self.status, "cannot write an unowned status")
        status = self.status
        lines = ["Shared engineering synchronization", "",
                 f"Head: `{status['head']}`", f"Source: `{status['source']}`",
                 f"Payload SHA256: `{status['digest']}`", f"Phase: {status['phase']}; outcome: {status['outcome']}."]
        if status.get("merge"):
            lines.append(f"Merged revision: `{status['merge']}`.")
        if status.get("dispatch_requested_at"):
            lines.append(f"Main ci.yml workflow_dispatch requested: {status['dispatch_requested_at']}.")
        if status.get("run_id"):
            lines.append(f"Run: https://github.com/{self.repository}/actions/runs/{status['run_id']} (workflow_dispatch, ci.yml).")
            if status.get("run_attempt"):
                lines.append(f"Run attempt: {status['run_attempt']}.")
        if status.get("tested_sha"):
            lines.append(f"Tested main revision: `{status['tested_sha']}` (may be a descendant of the merge).")
        if status["outcome"] == "failed":
            lines.append("Not qualified: retain this evidence. The next scheduled/manual attempt inspects this same PR; completed failed CI is not automatically rerun.")
        lines += ["", f"<!-- {STATUS} {json.dumps(status, sort_keys=True, separators=(',', ':'))} -->"]
        endpoint = (f"repos/{self.repository}/issues/comments/{self.status_id}" if self.status_id
                    else f"repos/{self.repository}/issues/{self.pr['number']}/comments")
        value = self.api(endpoint, "PATCH" if self.status_id else "POST", {"body": "\n".join(lines) + "\n"})
        require(isinstance(value, dict), "status comment write was not confirmed")
        self.status_id = number(value.get("id"), "comment ID")

    def workflow(self, name):
        if name not in self.workflow_ids:
            value = self.api(f"repos/{self.repository}/actions/workflows/{name}")
            require(isinstance(value, dict) and value.get("path") == f".github/workflows/{name}"
                    and value.get("state") == "active", "required workflow identity or enabled state refused")
            self.workflow_ids[name] = number(value.get("id"), "workflow ID")
        return self.workflow_ids[name]

    def validate_run(self, run, name, *, pr=None, base=None, head=None):
        require(isinstance(run, dict) and run.get("workflow_id") == self.workflow(name),
                "run does not belong to the trusted required workflow")
        number(run.get("id"), "run ID")
        require(run.get("repository", {}).get("full_name") == self.repository
                and run.get("head_repository", {}).get("full_name") == self.repository,
                "workflow run repository identity refused")
        require(run.get("path") == f".github/workflows/{name}", "workflow run path identity refused")
        object_id(run.get("head_sha"), "run head")
        number(run.get("run_attempt"), "workflow run attempt")
        if pr:
            require(run.get("event") == "pull_request" and run.get("head_branch") == BRANCH
                    and run.get("head_sha") == head, "PR workflow run event/ref/head mismatch")
            links = run.get("pull_requests")
            require(isinstance(links, list) and len(links) == 1, "PR workflow run has ambiguous PR association")
            link = links[0]
            require(link.get("number") == pr["number"]
                    and link.get("head", {}).get("sha") == head
                    and link.get("head", {}).get("ref") == BRANCH
                    and link.get("head", {}).get("repo", {}).get("id") == pr["head"]["repo"].get("id")
                    and link.get("base", {}).get("sha") == base
                    and link.get("base", {}).get("ref") == "main"
                    and link.get("base", {}).get("repo", {}).get("id") == pr["base"]["repo"].get("id"),
                    "PR workflow run lacks exact head/base association")
        else:
            require(run.get("event") == "workflow_dispatch" and run.get("head_branch") == "main",
                    "main evidence is not a main workflow dispatch")
        return run

    def run_detail(self, run_id):
        return self.api(f"repos/{self.repository}/actions/runs/{number(run_id)}")

    def run_jobs(self, run, required):
        jobs = self.pages(f"repos/{self.repository}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs")
        for name in required:
            matching = [job for job in jobs if job.get("name") == name]
            require(len(matching) == 1, "required job missing, duplicated or contradictory")
            job = matching[0]
            require(job.get("head_sha") == run["head_sha"] and job.get("status") == "completed"
                    and job.get("conclusion") == "success", "required job is not successful for the exact run head")
        require(run.get("status") == "completed" and run.get("conclusion") == "success",
                "required workflow run did not complete successfully")

    def integration_head(self, pr, base, head):
        self.git("fetch", "--no-tags", "origin", f"refs/pull/{pr['number']}/merge")
        integration = self.rev("FETCH_HEAD")
        parents = self.git("rev-list", "--parents", "-n", "1", integration).decode().split()
        require(parents == [integration, base, head], "PR integration revision does not join the reviewed base and head")
        return integration

    def discover_pr_runs(self, pr, base, head):
        self.phase = "PR run discovery"
        found = {}
        while len(found) != 2:
            for name in ("ci.yml", "agent-policy.yml"):
                if name in found:
                    continue
                runs = self.pages(f"repos/{self.repository}/actions/workflows/{self.workflow(name)}/runs?event=pull_request&head_sha={head}", "workflow_runs")
                candidates = [run for run in runs if run.get("head_sha") == head]
                require(len(candidates) <= 1, "multiple required PR workflow runs are ambiguous")
                if candidates:
                    run = self.validate_run(self.run_detail(number(candidates[0].get("id"))), name,
                                            pr=pr, base=base, head=head)
                    found[name] = run["id"]
                    self.pr_attempts[run["id"]] = run["run_attempt"]
            if len(found) != 2:
                self.pause()
        return found

    def observe_pr(self, pr, base, head):
        self.phase = "PR integration discovery"
        self.limit = min(time.monotonic() + DISCOVERY_SECONDS, self.deadline - MAIN_SECONDS)
        merge_ref = f"refs/pull/{pr['number']}/merge"
        while True:
            remote = self.git("ls-remote", "origin", merge_ref).decode().split()
            if remote:
                require(len(remote) == 2 and remote[1] == merge_ref, "ambiguous PR integration ref")
                object_id(remote[0], "integration ref")
                break
            self.pause()
        self.integration = self.integration_head(pr, base, head)
        runs = self.discover_pr_runs(pr, base, head)
        self.pr_runs = list(runs.values())
        self.phase = "PR CI"
        self.limit = min(time.monotonic() + PR_SECONDS, self.deadline - MAIN_SECONDS)
        pending = dict(runs)
        approved = set()
        while pending:
            current = self.pull(pr["number"])
            require(current.get("state") == "open" and current["head"]["sha"] == head
                    and current["base"]["sha"] == base, "PR head/base/state changed while observing CI")
            self.holds(current)
            for name, run_id in list(pending.items()):
                run = self.validate_run(self.run_detail(run_id), name, pr=pr, base=base, head=head)
                require(run["run_attempt"] == self.pr_attempts[run_id], "PR run attempt changed during observation")
                parked = run.get("conclusion") == "action_required" or run.get("status") == "action_required"
                if parked:
                    if run_id not in approved:
                        self.api(f"repos/{self.repository}/actions/runs/{run_id}/approve", "POST")
                        approved.add(run_id)
                    continue
                if run.get("status") == "completed":
                    self.run_jobs(run, REQUIRED[self.repository] if name == "ci.yml" else ("agent-policy",))
                    del pending[name]
                else:
                    require(run.get("status") in {"queued", "in_progress", "waiting", "pending", "requested"}
                            and run.get("conclusion") is None, "contradictory PR run status")
            if pending:
                self.pause()
        return runs

    def freshness(self, base):
        require(self.fetch_main() == base, "main advanced; candidate requires fresh integration CI")
        self.git("fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main", cwd=self.source)
        current = self.git("show", f"refs/remotes/origin/main:{SOURCE_PATH}", cwd=self.source)
        require(self.validate_payload(current) == self.digest,
                "canonical payload changed; candidate requires a fresh policy update")
        require(self.rev("HEAD", cwd=self.source) == self.source_sha
                and not self.git("status", "--porcelain=v1", "--untracked-files=all", cwd=self.source),
                "pinned source checkout changed during the attempt")

    def protection(self, pr, base, head):
        # The REST protection-admin endpoint requires Administration(read),
        # which a repository GITHUB_TOKEN cannot request. Read the applicable
        # base-ref rule alongside the PR's effective mergeability instead.
        query = """query($owner:String!,$name:String!,$number:Int!){
          repository(owner:$owner,name:$name){pullRequest(number:$number){
            headRefOid baseRefOid isDraft mergeable mergeStateStatus reviewDecision
            baseRef{branchProtectionRule{requiresStrictStatusChecks
              requiredStatusChecks{context app{databaseId}}}}
            commits(last:1){nodes{commit{statusCheckRollup{state}}}}
          }}
        }"""
        owner, name = self.repository.split("/")
        data = self.graphql(query, {"owner": owner, "name": name, "number": pr["number"]})
        value = data.get("repository", {}).get("pullRequest")
        require(isinstance(value, dict) and value.get("headRefOid") == head and value.get("baseRefOid") == base,
                "mergeability evidence does not match the tested head/base")
        rule = value.get("baseRef", {}).get("branchProtectionRule")
        require(isinstance(rule, dict) and rule.get("requiresStrictStatusChecks") is True,
                "strict main required checks are not configured or visible")
        checks = rule.get("requiredStatusChecks")
        require(isinstance(checks, list), "required check application identities are unavailable")
        for context in (*REQUIRED[self.repository], "agent-policy"):
            require(any(row.get("context") == context and (row.get("app") or {}).get("databaseId") == 15368
                        for row in checks), "required GitHub Actions check protection is missing")
        require(value.get("isDraft") is False
                and value.get("reviewDecision") not in {"CHANGES_REQUESTED", "REVIEW_REQUIRED"},
                "server-side readiness or required review protections block merge")
        if value.get("mergeable") == "UNKNOWN" or value.get("mergeStateStatus") == "UNKNOWN":
            return False
        require(value.get("mergeable") == "MERGEABLE" and value.get("mergeStateStatus") == "CLEAN",
                "server-side mergeability or required protections block merge")
        nodes = value.get("commits", {}).get("nodes", [])
        require(len(nodes) == 1 and nodes[0].get("commit", {}).get("statusCheckRollup", {}).get("state") == "SUCCESS",
                "server-side current-head status rollup is not successful")
        return True

    def cleanup_branch(self, pr):
        remote = self.branch_head()
        if remote is None:
            return
        require(remote == pr["head"]["sha"], "merged bot branch head changed; cleanup refused")
        self.git("push", f"--force-with-lease=refs/heads/{BRANCH}:{remote}",
                 "origin", f":refs/heads/{BRANCH}")
        require(self.branch_head() is None, "owned branch deletion was not confirmed")

    def main_candidates(self, pr, after):
        runs = self.pages(f"repos/{self.repository}/actions/workflows/{self.workflow('ci.yml')}/runs?event=workflow_dispatch&branch=main", "workflow_runs")
        candidates = []
        for brief in runs:
            created = instant(brief.get("created_at"))
            if created < after:
                continue
            run = self.validate_run(self.run_detail(number(brief.get("id"))), "ci.yml")
            self.git("fetch", "--no-tags", "origin", run["head_sha"])
            require(self.ancestor(pr["merge_commit_sha"], run["head_sha"])
                    and self.ancestor(run["head_sha"], self.main),
                    "main dispatch is not a reviewed descendant of the policy merge")
            candidates.append(run)
        return sorted(candidates, key=lambda run: (instant(run["created_at"]), run["id"]))

    def observe_main(self, pr, *, preserve_branch=False):
        """Recover dispatch/observation before returning content-current.

        The status is persisted before dispatch. A lost HTTP response is resolved
        by discovery on the next run, not by pretending current bytes prove CI.
        """
        self.phase = "post-merge main CI"
        self.limit = min(time.monotonic() + MAIN_SECONDS, self.deadline)
        self.pr, self.pr_owned = pr, True
        self.head = pr["head"]["sha"]
        merge = object_id(pr.get("merge_commit_sha"), "merge revision")
        require(pr.get("merged_at") is not None, "post-merge observation requires a confirmed merge")
        self.main = self.fetch_main()
        require(self.ancestor(merge, self.main), "policy merge is not an ancestor of consumer main")
        self.load_status(pr)
        previous_status = dict(self.status) if self.status else None
        if self.status is None:
            meta = metadata(pr)
            self.status = {"version": 1, "head": self.head, "source": meta["source"], "digest": meta["digest"],
                           "merge": merge, "phase": "main", "outcome": "pending", "evidence_after": pr["merged_at"]}
        else:
            self.status.update({"merge": merge, "phase": "main"})
            self.status.setdefault("evidence_after", pr["merged_at"])
        after = instant(self.status["evidence_after"])
        require(after >= instant(pr["merged_at"]), "main evidence predates the policy merge")
        if self.status.get("run_id"):
            run = self.validate_run(self.run_detail(self.status["run_id"]), "ci.yml")
            require(instant(run.get("created_at")) >= after, "recorded run predates main evidence boundary")
            self.git("fetch", "--no-tags", "origin", run["head_sha"])
            require(self.ancestor(merge, run["head_sha"]) and self.ancestor(run["head_sha"], self.main),
                    "recorded main run does not test the merge or a reviewed descendant")
            require(not self.status.get("tested_sha") or self.status["tested_sha"] == run["head_sha"],
                    "recorded main tested SHA changed")
        else:
            # Even an earlier failed matching dispatch is evidence to retain;
            # choosing a later green run would silently rerun-until-green.
            candidates = self.main_candidates(pr, after)
            run = candidates[0] if candidates else None
            if run is None:
                if "dispatch_requested_at" in self.status:
                    # Allow an accepted dispatch's run to become visible before
                    # making a new request after an earlier transport failure.
                    discovery = min(time.monotonic() + DISCOVERY_SECONDS, self.limit)
                    while time.monotonic() < discovery:
                        candidates = self.main_candidates(pr, after)
                        if candidates:
                            run = candidates[0]
                            break
                        self.pause()
                if run is None:
                    self.status.update({"dispatch_requested_at": timestamp(), "outcome": "pending"})
                    self.save_status()
                    self.api(f"repos/{self.repository}/actions/workflows/ci.yml/dispatches", "POST", {"ref": "main"})
                    discovery = min(time.monotonic() + DISCOVERY_SECONDS, self.limit)
                    while run is None:
                        require(time.monotonic() < discovery, "dispatched main run did not appear before discovery deadline")
                        self.main = self.fetch_main()
                        candidates = self.main_candidates(pr, after)
                        if candidates:
                            run = candidates[0]
                        else:
                            self.pause()
        require(run["run_attempt"] >= self.status.get("run_attempt", 1), "recorded main run attempt regressed")
        self.status.update({"run_id": run["id"], "run_attempt": run["run_attempt"], "tested_sha": run["head_sha"]})
        if run.get("status") != "completed":
            self.status["outcome"] = "pending"
            self.save_status()
        while True:
            if run.get("status") == "completed":
                self.run_jobs(run, REQUIRED[self.repository])
                break
            require(run.get("status") in {"queued", "in_progress", "waiting", "pending", "requested"}
                    and run.get("conclusion") is None, "main run failed, requires approval or has contradictory status")
            self.pause()
            run = self.validate_run(self.run_detail(run["id"]), "ci.yml")
            require(run["head_sha"] == self.status["tested_sha"], "main run tested SHA changed")
            require(run["run_attempt"] == self.status["run_attempt"], "main run attempt changed during observation")
        self.status.update({"phase": "complete", "outcome": "success"})
        if self.status != previous_status:
            self.save_status()
        if not preserve_branch:
            self.cleanup_branch(pr)
        self.limit = self.deadline

    def candidate(self, open_pr, remote):
        desired_tree, content, changed = self.expected_tree(self.main, self.source_bytes)
        if not changed:
            if open_pr:
                self.holds(open_pr)
                self.verify_owned(open_pr)
                require(remote == open_pr["head"]["sha"], "obsolete bot branch head race")
                require(self.rev(f"{self.main}^{{tree}}") == desired_tree,
                        "obsolete PR is not represented on main")
                # Reconstructing both candidates with the same source proves
                # this old generated-only diff is already present, even when
                # unrelated main files have advanced.
                old_meta = metadata(open_pr)
                _, old_current, _ = self.expected_tree(self.main, self.source_data(old_meta["source"]))
                require(old_current == content, "obsolete PR has unique policy content not present on main")
                self.api(f"repos/{self.repository}/pulls/{open_pr['number']}", "PATCH", {"state": "closed"})
                closed = self.pull(open_pr["number"])
                require(closed.get("state") == "closed" and closed.get("merged_at") is None
                        and closed["head"]["sha"] == remote, "obsolete PR closure was not confirmed")
                self.git("push", f"--force-with-lease=refs/heads/{BRANCH}:{remote}", "origin", f":refs/heads/{BRANCH}")
            return None
        meta = {"base": self.main, "source": self.source_sha, "digest": self.digest}
        if open_pr:
            old_meta = self.verify_owned(open_pr)
            self.holds(open_pr)
            require(remote == open_pr["head"]["sha"], "bot branch differs from verified PR head")
            # Source revision movement without a payload change is not churn.
            if (old_meta["base"] == self.main and old_meta["digest"] == self.digest
                    and self.rev(f"{remote}^{{tree}}") == desired_tree):
                self.pr, self.pr_owned, self.head = open_pr, True, remote
                return open_pr
            if not open_pr.get("draft"):
                self.draft(open_pr)
        else:
            require(remote is None, "orphan reserved bot branch refused")
        self.phase = "candidate publication"
        self.git("checkout", "--detach", self.main)
        (self.checkout / "AGENTS.md").write_bytes(content)
        self.git("add", "--", "AGENTS.md")
        require(self.rev_tree_index() == desired_tree, "publication tree differs from generated-only candidate")
        self.git("commit", "-m", TITLE)
        head = self.rev("HEAD")
        require(self.branch_head() == remote, "reserved branch raced before publication")
        if open_pr:
            current = self.pull(open_pr["number"])
            require(current.get("state") == "open" and current.get("draft") is True
                    and current["head"]["sha"] == remote and metadata(current) == old_meta,
                    "owned draft head/state/metadata raced before replacement")
            self.holds(current)
        self.git("push", f"--force-with-lease=refs/heads/{BRANCH}:{remote or ''}",
                 "origin", f"{head}:refs/heads/{BRANCH}")
        require(self.branch_head() == head, "candidate push was not confirmed")
        if open_pr:
            require(self.pull(open_pr["number"])["head"]["sha"] == head, "PR head did not follow candidate push")
            pr = self.api(f"repos/{self.repository}/pulls/{open_pr['number']}", "PATCH",
                          {"title": TITLE, "body": self.body(meta)})
        else:
            pr = self.api(f"repos/{self.repository}/pulls", "POST",
                          {"title": TITLE, "head": BRANCH, "base": "main", "body": self.body(meta), "draft": True})
        self.pr_identity(pr)
        require(pr["head"]["sha"] == head and pr.get("draft") is True, "published draft head not confirmed")
        self.pr, self.pr_owned, self.head = pr, True, head
        # A replaced head invalidates prior status evidence. Update only the
        # existing bot-owned status comment, preserving all unrelated comments.
        comments = self.pages(f"repos/{self.repository}/issues/{pr['number']}/comments")
        owned = [row for row in comments if row.get("user", {}).get("login") == BOT
                 and f"<!-- {STATUS} " in (row.get("body") or "")]
        require(len(owned) <= 1, "ambiguous owned status comments")
        self.status_id = number(owned[0]["id"]) if owned else None
        self.status = {"version": 1, "head": head, "source": meta["source"], "digest": meta["digest"],
                       "phase": "pr", "outcome": "pending"}
        self.save_status()
        return pr

    def rev_tree_index(self):
        return object_id(self.git("write-tree").decode().strip())

    def merge(self, pr):
        self.phase = "pre-merge validation"
        self.limit = self.deadline - MAIN_SECONDS
        meta = metadata(pr)
        base, head = meta["base"], pr["head"]["sha"]
        self.freshness(base)
        current = self.pull(pr["number"])
        require(current.get("state") == "open" and current["head"]["sha"] == head
                and current["base"]["sha"] == base, "PR changed after successful CI")
        self.holds(current)
        self.verify_owned(current)
        require(self.branch_head() == head, "branch head changed after successful CI")
        require(self.integration_head(current, base, head) == self.integration,
                "tested integration revision changed")
        for name, run_id in self.pr_run_map.items():
            run = self.validate_run(self.run_detail(run_id), name, pr=current, base=base, head=head)
            require(run["run_attempt"] == self.pr_attempts[run_id], "PR CI attempt changed after verification")
            self.run_jobs(run, REQUIRED[self.repository] if name == "ci.yml" else ("agent-policy",))
        self.api(f"repos/{self.repository}/pulls/{pr['number']}", "PATCH",
                 {"body": self.body(meta, self.pr_runs)})
        if current.get("draft"):
            self.draft(current, ready=True)
        # Allow only UNKNOWN mergeability to settle for a finite window.
        # Known failed protections are never polled until green or bypassed.
        self.phase = "merge protection"
        current = self.pull(pr["number"])
        self.holds(current)
        protection_deadline = min(time.monotonic() + 60, self.limit)
        while not self.protection(current, base, head):
            require(time.monotonic() < protection_deadline, "mergeability remained unknown")
            self.pause()
            current = self.pull(pr["number"])
            self.holds(current)
        self.freshness(base)
        current = self.pull(pr["number"])
        self.holds(current)
        require(current["head"]["sha"] == head and current["base"]["sha"] == base
                and current.get("state") == "open", "final PR head/base race")
        self.phase = "squash merge"
        value = self.api(f"repos/{self.repository}/pulls/{pr['number']}/merge", "PUT",
                         {"sha": head, "merge_method": "squash", "commit_title": TITLE})
        require(isinstance(value, dict) and value.get("merged") is True, "server rejected guarded squash merge")
        merged = self.pull(pr["number"])
        require(merged.get("merged") is True and merged.get("state") == "closed"
                and merged["head"]["sha"] == head
                and object_id(value.get("sha")) == merged.get("merge_commit_sha"),
                "squash merge outcome was not confirmed")
        self.pr = merged
        self.limit = self.deadline
        self.cleanup_branch(merged)
        self.observe_main(merged)

    def run(self):
        self.initialize()
        self.phase = "existing policy ownership"
        pulls = self.list_pulls()
        open_pulls = [pr for pr in pulls if pr.get("state") == "open"]
        require(len(open_pulls) <= 1, "multiple reserved-branch PRs require maintainer coordination")
        open_pr = self.pull(open_pulls[0]["number"]) if open_pulls else None
        if open_pr:
            self.pr, self.head = open_pr, open_pr["head"]["sha"]
            self.verify_owned(open_pr)
            self.pr_owned = True
        # Recovery precedes rendering/no-op. Later source policy cannot relabel
        # a completed failed main run as qualified or cause an automatic rerun.
        merged = [pr for pr in pulls if pr.get("merged_at") is not None]
        if merged:
            latest = max(merged, key=lambda pr: (instant(pr["merged_at"]), number(pr["number"])))
            latest = self.pull(latest["number"])
            self.pr, self.head, self.pr_owned = latest, latest["head"]["sha"], False
            self.verify_owned(latest)
            self.observe_main(latest, preserve_branch=open_pr is not None)
            self.pr, self.pr_owned, self.status, self.status_id = None, False, None, None
            self.head = None
            self.main = self.fetch_main()
        self.phase = "existing policy ownership"
        self.limit = self.deadline - MAIN_SECONDS
        remote = self.branch_head()
        require(remote is None or open_pr is not None, "orphan reserved bot branch refused")
        # Closing is a digest-scoped hold; reopening that same PR is the sole
        # machine-recognized resumption. No label/comment clearance language.
        for closed in pulls:
            if closed.get("state") == "closed" and closed.get("merged_at") is None:
                closed = self.pull(number(closed.get("number")))
                closed_meta = self.pr_identity(closed)
                if closed_meta["digest"] == self.digest:
                    self.pr, self.head, self.pr_owned = closed, closed["head"]["sha"], False
                    events = self.pages(f"repos/{self.repository}/issues/{closed['number']}/events")
                    closures = [event for event in events if event.get("event") == "closed"]
                    require(closures, "closed policy PR lacks closure ownership evidence")
                    closure = max(closures, key=lambda event: number(event.get("id"), "event ID"))
                    require(closure.get("actor", {}).get("login") == BOT,
                            "maintainer-closed unmerged policy PR holds this source digest; reopen it to resume")
                    self.verify_owned(closed)
                    self.holds(closed)
                    _, _, old_changes_main = self.expected_tree(self.main, self.source_data(closed_meta["source"]))
                    require(not old_changes_main, "bot-closed PR has unique policy content; maintainer intervention required")
                    self.pr, self.head = None, None
        if open_pr:
            self.pr, self.head = open_pr, open_pr["head"]["sha"]
            self.verify_owned(open_pr)
            self.pr_owned = True
            self.holds(open_pr)
        pr = self.candidate(open_pr, remote)
        if pr is None:
            return "policy content current"
        self.pr, self.pr_owned, self.head = pr, True, pr["head"]["sha"]
        if self.status is None:
            self.load_status(pr)
        meta = metadata(pr)
        if self.status is None:
            self.status = {"version": 1, "head": self.head, "source": meta["source"], "digest": meta["digest"],
                           "phase": "pr", "outcome": "pending"}
            self.save_status()
        require(meta["base"] == self.main and meta["digest"] == self.digest,
                "candidate does not match current base/payload")
        self.pr_run_map = self.observe_pr(pr, meta["base"], self.head)
        self.merge(pr)
        return "policy merged; required PR CI and explicit main CI confirmed"

    def report(self, message, failed=False):
        # Messages are fixed local diagnostics, never API bodies, stderr, tokens,
        # arbitrary issue text or checkout contents.
        lines = [f"Agent policy: {message}", f"Phase: {self.phase}"]
        if self.source_sha:
            lines.append(f"Source revision: {self.source_sha}")
        if self.digest:
            lines.append(f"Payload SHA256: {self.digest}")
        if self.main:
            lines.append(f"Consumer main snapshot: {self.main}")
        if self.head:
            lines.append(f"Consumer head: {self.head}")
        if self.pr:
            lines.append(f"PR: https://github.com/{self.repository}/pull/{self.pr['number']}")
        main_confirmed = bool(self.status and self.status.get("phase") == "complete"
                              and self.status.get("outcome") == "success")
        if failed and self.pr and self.pr.get("merged_at"):
            if main_confirmed:
                lines.append("State: merged with confirmed main CI; a subsequent operation failed, so retain that successful CI evidence.")
            else:
                lines.append("State: merged-but-main-unverified; no rollback or completed-failure rerun is attempted.")
        if failed:
            lines.append("Next automatic attempt: the next hourly schedule (or main manual dispatch) inspects the same owned PR and pending phase; maintainer holds and completed CI failures require resolution, not automatic reruns.")
        text = "\n".join(lines) + "\n"
        print(text, end="")
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            try:
                with open(summary, "a", encoding="utf-8") as output:
                    output.write(text + "\n")
            except OSError:
                print("Agent policy: workflow summary could not be written", file=sys.stderr)
        if failed and self.pr_owned and self.status and not main_confirmed:
            self.status["outcome"] = "failed"
            self.limit = self.deadline
            try:
                self.save_status()
            except (Blocked, OSError):
                print("Agent policy: failure status comment could not be persisted; workflow summary remains the evidence boundary", file=sys.stderr)

    def cleanup(self):
        if self.checkout_owned and self.checkout.exists():
            try:
                shutil.rmtree(self.checkout)
            except OSError:
                print("Agent policy: run-owned checkout cleanup failed", file=sys.stderr)
                return False
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--source-checkout", required=True)
    parser.add_argument("--work-dir", required=True)
    args = parser.parse_args()
    sync = Sync(args)
    code = 0
    try:
        message = sync.run()
        sync.report(message)
    except Invalid as error:
        sync.report(str(error), failed=True)
        code = 2
    except (Blocked, OSError, UnicodeError, ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
        message = str(error) if isinstance(error, Blocked) else "invalid response or local I/O; synchronization stopped"
        sync.report(message, failed=True)
        code = 1
    finally:
        if not sync.cleanup():
            code = 1
    return code


if __name__ == "__main__":
    sys.exit(main())

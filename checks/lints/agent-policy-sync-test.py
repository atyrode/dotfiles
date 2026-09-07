#!/usr/bin/env python3
"""Exercise the synchronizer CLI with local Git objects and a fake GitHub API.

Usage: agent-policy-sync-test.py [path-to-sync.py [path-to-renderer.py]]
The two executable fixtures are the only substitution boundary. Git still
performs ancestry, complete-tree comparison, commits, merges and leased pushes;
no production Python helpers are imported and no network or credentials are used.
"""

import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit


SELF = Path(__file__).resolve()
BEGIN = b"<!-- BEGIN SHARED ENGINEERING: generated; do not edit -->"
END = b"<!-- END SHARED ENGINEERING -->"
OLD = b"## Common engineering contract\n\n- Preserve evidence.\n"
NEW = b"## Common engineering contract\n\n- Preserve evidence and its limits.\n"
NEXT = b"## Common engineering contract\n\n- Preserve evidence, limits and ownership.\n"
PREFIX = b"# Consumer\n\nLocally authored introduction.\n\n"
SUFFIX = b"\n## Local authority\n\nNever modify these local instructions.\n"
POLICY_PATH = "modules/home/agents/engineering.md"
BRANCH = "bot/agent-policy"
TITLE = "chore(policy): synchronize shared engineering contract"
REQUIRED = {"code": ["test"], "babel": ["test", "race", "web", "browser"], "manifold": ["gate"]}


def envelope(payload):
    return (
        BEGIN
        + b"\n\n<!-- prettier-ignore-start -->\n"
        + b"<!-- Source: https://github.com/atyrode/dotfiles/blob/main/modules/home/agents/engineering.md -->\n"
        + b"<!-- SHA256: " + hashlib.sha256(payload).hexdigest().encode() + b" -->\n\n"
        + payload
        + b"\n<!-- prettier-ignore-end -->\n\n"
        + END + b"\n"
    )


class Refused(Exception):
    """A deliberate server or transport refusal, not a broken fixture."""


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def git(*args, cwd=None, data=None, check=True):
    fixture_env = os.environ | {
        "GIT_AUTHOR_NAME": "Policy fixture", "GIT_AUTHOR_EMAIL": "policy@example.invalid",
        "GIT_COMMITTER_NAME": "Policy fixture", "GIT_COMMITTER_EMAIL": "policy@example.invalid",
        "GIT_ALLOW_PROTOCOL": "file",
    }
    return subprocess.run(
        [os.environ.get("POLICY_TEST_REAL_GIT", "git"), *map(str, args)],
        cwd=cwd, input=data, env=fixture_env, capture_output=True, check=check, timeout=15,
    )


def git_text(*args, cwd=None):
    return git(*args, cwd=cwd).stdout.decode().strip()


def load_state():
    return json.loads(Path(os.environ["POLICY_TEST_STATE"]).read_text())


def save_state(state):
    Path(os.environ["POLICY_TEST_STATE"]).write_text(json.dumps(state))


def record(state, kind, **values):
    state["events"].append({"kind": kind, **values})


def ref_sha(state, ref="main"):
    return git_text("--git-dir", state["consumer_remote"], "rev-parse", "refs/heads/" + ref)


def public_repo(state):
    return {
        "id": 100, "full_name": state["repository"], "name": state["name"],
        "default_branch": "main", "fork": state.get("fork", False),
        "owner": {"login": "atyrode"}, "permissions": {"push": True},
        "allow_squash_merge": True,
    }


def pull_view(state, pull):
    result = dict(pull)
    repo = public_repo(state)
    result.update({
        "url": f"https://api.github.com/repos/{state['repository']}/pulls/{pull['number']}",
        "html_url": f"https://github.com/{state['repository']}/pull/{pull['number']}",
        "head": {"sha": pull["sha"], "ref": BRANCH, "repo": repo},
        "base": {"sha": ref_sha(state), "ref": "main", "repo": repo},
        "labels": [{"name": name} for name in state.get("labels", [])],
        "mergeable": True, "mergeable_state": state.get("mergeable_state", "clean"),
        "node_id": "PR_fixture_1", "maintainer_can_modify": False,
    })
    if state.get("foreign_head"):
        result["head"]["repo"] = {**repo, "full_name": "outsider/code", "fork": True}
    return result


def sync_pull_refs(state, pull):
    remote = state["consumer_remote"]
    head = pull["sha"]
    base = ref_sha(state)
    git("--git-dir", remote, "update-ref", f"refs/pull/{pull['number']}/head", head)
    if pull.get("integration_base") != base or pull.get("integration_head") != head:
        tree = git_text("--git-dir", remote, "rev-parse", head + "^{tree}")
        integration = git("--git-dir", remote, "commit-tree", tree, "-p", base, "-p", head, data=b"PR integration fixture\n").stdout.decode().strip()
        git("--git-dir", remote, "update-ref", f"refs/pull/{pull['number']}/merge", integration)
        pull.update({"integration_base": base, "integration_head": head, "integration_sha": integration})


def make_pull(state, body, *, draft=True, author="github-actions[bot]", closed=False):
    pull = {
        "number": len(state["pulls"]) + 1, "title": TITLE, "body": body,
        "state": "closed" if closed else "open", "draft": draft,
        "user": {"login": author, "type": "Bot" if author == "github-actions[bot]" else "User"},
        "sha": ref_sha(state, BRANCH), "merged": False, "merged_at": None,
        "created_at": timestamp(), "updated_at": timestamp(), "closed_at": timestamp() if closed else None,
    }
    state["pulls"].append(pull)
    sync_pull_refs(state, pull)
    return pull


def make_runs(state, pull=None, event="pull_request"):
    sha = pull["sha"] if pull else ref_sha(state)
    workflows = ["ci.yml", "agent-policy.yml"] if pull else ["ci.yml"]
    created = []
    for workflow in workflows:
        names = REQUIRED[state["name"]] if workflow == "ci.yml" else ["agent-policy"]
        conclusion = state.get("job_conclusion", "success") if pull else state.get("main_conclusion", "success")
        jobs = [
            {"id": 1000 + index, "name": name, "head_sha": sha, "status": "completed", "conclusion": conclusion}
            for index, name in enumerate(names)
            if name != state.get("missing_job")
        ]
        run_id = 100 + len(state["runs"])
        run = {
            "id": run_id, "workflow_id": 10 if workflow == "ci.yml" else 20,
            "name": "ci" if workflow == "ci.yml" else "agent-policy",
            "path": ".github/workflows/" + workflow, "workflow": workflow,
            "event": event, "head_sha": sha, "head_branch": BRANCH if pull else "main",
            "head_repository": public_repo(state), "repository": public_repo(state),
            "pull_requests": ([{
                "number": pull["number"],
                "head": {"sha": sha, "ref": BRANCH, "repo": public_repo(state)},
                "base": {"sha": ref_sha(state), "ref": "main", "repo": public_repo(state)},
            }] if pull else []),
            "status": "completed",
            "conclusion": "action_required" if pull and state.get("park_runs", True) else conclusion,
            "created_at": timestamp(), "updated_at": timestamp(), "run_started_at": timestamp(),
            "run_attempt": 1, "html_url": f"https://github.com/{state['repository']}/actions/runs/{run_id}",
            "jobs": jobs,
        }
        state["runs"].append(run)
        created.append(run)
    return created


def append_remote_commit(state, remote_key, path, content):
    remote = state[remote_key]
    with tempfile.TemporaryDirectory(dir=state["base"]) as temp:
        git("clone", "--quiet", remote, temp)
        target = Path(temp) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        git("add", "--", path, cwd=temp)
        git("commit", "--quiet", "-m", "Concurrent reviewed update", cwd=temp)
        git("push", "--quiet", "origin", "main", cwd=temp)


def fake_git():
    state = load_state()
    args = sys.argv[2:]
    record(state, "git", argv=args)
    if "fetch" in args and state.get("source_fetch_failure") and Path.cwd() == Path(state["source_checkout"]):
        save_state(state)
        print("Synthetic canonical source fetch failure", file=sys.stderr)
        sys.exit(1)
    # Strip only authentication configuration; everything else, especially
    # expected-head leases and revision checks, is executed by real Git.
    clean = []
    index = 0
    while index < len(args):
        if args[index] == "-c" and index + 1 < len(args) and args[index + 1].startswith("credential."):
            index += 2
        else:
            clean.append(args[index])
            index += 1
    mappings = [
        "-c", f"url.{state['consumer_remote']}.insteadOf=https://github.com/{state['repository']}.git",
        "-c", f"url.{state['source_remote']}.insteadOf=https://github.com/atyrode/dotfiles.git",
        "-c", "protocol.file.allow=always",
    ]
    if "remote" in clean and "get-url" in clean:
        mappings = []
    if "push" in clean and state.get("push_race") and not state.get("push_race_fired"):
        state["push_race_fired"] = True
        old = ref_sha(state, BRANCH)
        tree = git_text("--git-dir", state["consumer_remote"], "rev-parse", old + "^{tree}")
        replacement = git("--git-dir", state["consumer_remote"], "commit-tree", tree, "-p", old, data=b"Concurrent head\n").stdout.decode().strip()
        git("--git-dir", state["consumer_remote"], "update-ref", "refs/heads/" + BRANCH, replacement, old)
    save_state(state)
    data = sys.stdin.buffer.read() if "--stdin" in clean else None
    proc = git(*mappings, *clean, data=data, check=False)
    if proc.returncode == 0 and "push" in clean:
        current = git("--git-dir", state["consumer_remote"], "rev-parse", "refs/heads/" + BRANCH, check=False)
        if current.returncode == 0:
            head = current.stdout.decode().strip()
            for pull in state["pulls"]:
                if pull["state"] == "open" and pull["sha"] != head:
                    pull["sha"] = head
                    sync_pull_refs(state, pull)
                    make_runs(state, pull)
    save_state(state)
    sys.stdout.buffer.write(proc.stdout)
    sys.stderr.buffer.write(proc.stderr)
    sys.exit(proc.returncode)


def graphql_response(state, payload):
    query = payload.get("query", "")
    pull = state["pulls"][-1] if state["pulls"] else None
    if "convertPullRequestToDraft" in query:
        pull["draft"] = True
        record(state, "draft", sha=pull["sha"])
        return {"data": {"convertPullRequestToDraft": {"pullRequest": {"isDraft": True}}}}
    if "markPullRequestReadyForReview" in query:
        pull["draft"] = False
        record(state, "ready", sha=pull["sha"])
        return {"data": {"markPullRequestReadyForReview": {"pullRequest": {"isDraft": False}}}}
    if "pullRequest" in query or "node(" in query:
        contexts = [
            {"__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": "SUCCESS"}
            for name in REQUIRED[state["name"]] + ["agent-policy"]
        ]
        view = {
            "id": "PR_fixture_1", "isDraft": pull["draft"], "headRefOid": pull["sha"],
            "baseRefOid": ref_sha(state), "mergeable": "MERGEABLE",
            "mergeStateStatus": "BLOCKED" if state.get("protection_blocked") else "CLEAN",
            "reviewDecision": "CHANGES_REQUESTED" if state.get("review_hold") else None,
            "baseRef": {"branchProtectionRule": {
                "requiresStrictStatusChecks": not state.get("non_strict"),
                "requiredStatusChecks": [
                    {"context": name, "app": {"databaseId": 15368}}
                    for name in REQUIRED[state["name"]] + ["agent-policy"]
                ],
            }},
            "commits": {"nodes": [{"commit": {"oid": pull["sha"], "statusCheckRollup": {
                "state": "SUCCESS", "contexts": {"nodes": contexts},
            }}}]},
        }
        return {"data": {"repository": {"pullRequest": view}, "node": view}}
    raise ValueError("Unrecognized GraphQL operation")


def api_response(state, method, endpoint, payload):
    parsed = urlsplit(endpoint)
    path = parsed.path.removeprefix("/")
    query = parse_qs(parsed.query)
    prefix = "repos/" + state["repository"]
    if path == "graphql":
        return graphql_response(state, payload)
    if path == prefix:
        return public_repo(state)
    if not path.startswith(prefix + "/"):
        raise ValueError("Unexpected repository endpoint: " + path)
    suffix = path[len(prefix) + 1:]
    parts = suffix.split("/")
    if suffix == "pulls":
        if method == "POST":
            pull = make_pull(state, payload["body"], draft=payload.get("draft", False))
            record(state, "create", draft=pull["draft"], sha=pull["sha"])
            make_runs(state, pull)
            return pull_view(state, pull)
        pulls = state["pulls"]
        requested = query.get("state", ["open"])[0]
        if requested != "all":
            pulls = [pull for pull in pulls if pull["state"] == requested]
        return [] if int(query.get("page", ["1"])[0]) > 1 else [pull_view(state, pull) for pull in reversed(pulls)]
    if parts[0] == "pulls" and len(parts) >= 2:
        pull = next(pull for pull in state["pulls"] if pull["number"] == int(parts[1]))
        if len(parts) == 2:
            if method == "PATCH":
                for key in ("body", "title", "state", "draft"):
                    if key in payload:
                        pull[key] = payload[key]
                if payload.get("state") == "closed":
                    pull["closed_by"] = "github-actions[bot]"
                    pull["closed_at"] = timestamp()
            return pull_view(state, pull)
        if parts[2] == "reviews":
            return ([{"id": 1, "user": {"login": "maintainer"}, "state": "CHANGES_REQUESTED", "submitted_at": timestamp()}]
                    if state.get("review_hold") else [])
        if parts[2] == "merge" and method == "PUT":
            if state.get("merge_head_race"):
                old = ref_sha(state, BRANCH)
                tree = git_text("--git-dir", state["consumer_remote"], "rev-parse", old + "^{tree}")
                replacement = git("--git-dir", state["consumer_remote"], "commit-tree", tree, "-p", old, data=b"Concurrent merge head\n").stdout.decode().strip()
                git("--git-dir", state["consumer_remote"], "update-ref", "refs/heads/" + BRANCH, replacement, old)
            if state.get("merge_base_race"):
                append_remote_commit(state, "consumer_remote", "concurrent.txt", b"Reviewed concurrent change.\n")
                raise Refused("Merge rejected by strict checks after base update")
            if payload.get("sha") != pull["sha"] or ref_sha(state, BRANCH) != pull["sha"]:
                raise Refused("Merge rejected: changed head")
            if state.get("merge_rejected"):
                raise Refused("Merge rejected by strict required checks")
            if state.get("labels") or state.get("review_hold") or pull["draft"]:
                raise Refused("Merge rejected: held or draft")
            base = ref_sha(state)
            tree = git_text("--git-dir", state["consumer_remote"], "rev-parse", pull["sha"] + "^{tree}")
            merged = git("--git-dir", state["consumer_remote"], "commit-tree", tree, "-p", base, data=b"Synchronize policy\n").stdout.decode().strip()
            git("--git-dir", state["consumer_remote"], "update-ref", "refs/heads/main", merged, base)
            pull.update({"state": "closed", "merged": True, "merged_at": timestamp(), "merge_commit_sha": merged})
            record(state, "merge", sha=pull["sha"], merged_sha=merged, method=payload.get("merge_method"))
            return {"merged": True, "sha": merged, "message": "Pull Request successfully merged"}
    if parts[0] == "issues" and len(parts) >= 3:
        if parts[2] == "events":
            pull = next(pull for pull in state["pulls"] if pull["number"] == int(parts[1]))
            return [{
                "id": 1, "event": "closed", "actor": {"login": pull.get("closed_by", "maintainer")},
                "created_at": pull["closed_at"],
            }] if pull["state"] == "closed" else []
        if parts[2] == "labels":
            return [{"name": name} for name in state.get("labels", [])]
        if parts[2] == "comments":
            if method == "POST":
                comment = {"id": len(state["comments"]) + 1, "body": payload["body"], "user": {"login": "github-actions[bot]"}, "created_at": timestamp()}
                state["comments"].append(comment)
                return comment
            return [] if int(query.get("page", ["1"])[0]) > 1 else state["comments"]
        if parts[1] == "comments" and method == "PATCH":
            comment = next(comment for comment in state["comments"] if comment["id"] == int(parts[2]))
            comment["body"] = payload["body"]
            return comment
    if suffix == "actions/runs" or (parts[:2] == ["actions", "workflows"] and len(parts) == 4 and parts[3] == "runs"):
        runs = state["runs"]
        if len(parts) == 4:
            workflow = parts[2]
            runs = [run for run in runs if workflow in (run["workflow"], str(run["workflow_id"]))]
        for key, field in (("event", "event"), ("head_sha", "head_sha"), ("branch", "head_branch")):
            if key in query:
                runs = [run for run in runs if run[field] == query[key][0]]
        return {"total_count": len(runs), "workflow_runs": [] if int(query.get("page", ["1"])[0]) > 1 else runs}
    if parts[:2] == ["actions", "workflows"]:
        workflow = parts[2]
        if len(parts) == 3:
            return {"id": 10 if workflow in ("ci.yml", "10") else 20, "path": ".github/workflows/" + ("ci.yml" if workflow in ("ci.yml", "10") else "agent-policy.yml"), "state": "active"}
        if parts[3] == "dispatches" and method == "POST":
            record(state, "dispatch", ref=payload.get("ref"))
            if state.get("dispatch_failures", 0):
                state["dispatch_failures"] -= 1
                if state.get("dispatch_accepted"):
                    make_runs(state, event="workflow_dispatch")
                raise Refused("Synthetic dispatch transport failure")
            make_runs(state, event="workflow_dispatch")
            return None
    if parts[:2] == ["actions", "runs"]:
        run = next(run for run in state["runs"] if run["id"] == int(parts[2]))
        if len(parts) == 3:
            return run
        if parts[3] == "jobs":
            return {"total_count": len(run["jobs"]), "jobs": run["jobs"]}
        if parts[3] == "approve" and method == "POST":
            record(state, "approve", run=run["id"])
            run["status"] = "completed"
            run["conclusion"] = state.get("job_conclusion", "success")
            if state.get("source_race") and not state.get("source_race_fired"):
                state["source_race_fired"] = True
                append_remote_commit(state, "source_remote", POLICY_PATH, NEXT)
            if state.get("base_race") and not state.get("base_race_fired"):
                state["base_race_fired"] = True
                append_remote_commit(state, "consumer_remote", "concurrent.txt", b"Reviewed concurrent change.\n")
            if state.get("hold_after_approval"):
                state["labels"] = ["blocked"]
            return {"message": "Approved"}
    raise ValueError(f"Unrecognized API request: {method} {endpoint}")


def fake_gh():
    state = load_state()
    args = sys.argv[2:]
    if not args or args[0] != "api":
        print("Only explicit gh api requests are fixture-supported", file=sys.stderr)
        sys.exit(90)
    method = "GET"
    endpoint = None
    payload = {}
    index = 1
    while index < len(args):
        arg = args[index]
        if arg in ("--method", "-X"):
            method = args[index + 1]
            index += 2
        elif arg == "--input":
            if args[index + 1] != "-":
                raise ValueError("JSON must arrive over stdin")
            payload = json.load(sys.stdin)
            index += 2
        elif arg in ("-H", "--header"):
            index += 2
        elif arg.startswith("-"):
            raise ValueError("Unexpected gh option: " + arg)
        elif endpoint is None:
            endpoint = arg
            index += 1
        else:
            raise ValueError("Unexpected gh argument: " + arg)
    record(state, "api", method=method, endpoint=endpoint, payload=payload)
    try:
        result = api_response(state, method, endpoint, payload)
    except Exception as error:
        if not isinstance(error, Refused):
            record(state, "fixture_error", message=repr(error))
        save_state(state)
        print(str(error), file=sys.stderr)
        sys.exit(1)
    save_state(state)
    if result is not None:
        print(json.dumps(result))


if len(sys.argv) > 1 and sys.argv[1] in ("--fake-git", "--fake-gh"):
    if sys.argv[1] == "--fake-git":
        fake_git()
    else:
        fake_gh()
    sys.exit(0)

SYNC = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else SELF.parents[2] / "ci/agent-policy-sync.py"
RENDERER = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else SELF.parents[2] / "ci/agent-policy.py"


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.real_git = shutil.which("git")
        self.assertIsNotNone(self.real_git, "Git is required for the real object/lease fixture")
        self.home = self.base / "home"
        self.home.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.state_file = self.base / "state.json"
        self.env = {
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
            "HOME": str(self.home), "LANG": "C.UTF-8", "TZ": "UTC",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Policy fixture", "GIT_AUTHOR_EMAIL": "policy@example.invalid",
            "GIT_COMMITTER_NAME": "Policy fixture", "GIT_COMMITTER_EMAIL": "policy@example.invalid",
            "GH_TOKEN": "synthetic-not-a-credential", "GITHUB_REPOSITORY": "atyrode/code",
            "GITHUB_EVENT_NAME": "schedule", "GITHUB_REF": "refs/heads/main",
            "GITHUB_SERVER_URL": "https://github.com", "GITHUB_API_URL": "https://api.github.com",
            "GITHUB_STEP_SUMMARY": str(self.base / "summary"), "GITHUB_RUN_ID": "1",
            "POLICY_TEST_REAL_GIT": self.real_git, "POLICY_TEST_STATE": str(self.state_file),
        }
        # Fixture construction also uses an isolated identity/configuration;
        # neither real caller credentials nor Git hooks are inherited.
        self.previous = os.environ.copy()
        os.environ.clear()
        os.environ.update(self.env)
        self.addCleanup(self.restore_environment)
        for name in ("git", "gh"):
            executable = self.bin / name
            executable.write_text(
                f"#!{sys.executable}\nimport runpy, sys\nsys.argv = [{str(SELF)!r}, '--fake-{name}', *sys.argv[1:]]\nrunpy.run_path({str(SELF)!r}, run_name='__main__')\n"
            )
            executable.chmod(0o755)
        self.source = self.base / "source"
        self.source.mkdir()
        self.init_repo(self.source)
        (self.source / "ci").mkdir()
        shutil.copyfile(RENDERER, self.source / "ci/agent-policy.py")
        shutil.copyfile(SYNC, self.source / "ci/agent-policy-sync.py")
        (self.source / POLICY_PATH).parent.mkdir(parents=True)
        (self.source / POLICY_PATH).write_bytes(OLD)
        self.commit(self.source, "Initial common source")
        self.old_source_sha = git_text("rev-parse", "HEAD", cwd=self.source)
        (self.source / POLICY_PATH).write_bytes(NEW)
        self.commit(self.source, "Reviewed common source update")
        self.source_sha = git_text("rev-parse", "HEAD", cwd=self.source)
        self.source_remote = self.base / "source.git"
        git("clone", "--quiet", "--bare", self.source, self.source_remote)
        git("remote", "add", "origin", "https://github.com/atyrode/dotfiles.git", cwd=self.source)
        self.consumer = self.base / "seed"
        self.consumer.mkdir()
        self.init_repo(self.consumer)
        (self.consumer / "AGENTS.md").write_bytes(PREFIX + envelope(OLD) + SUFFIX)
        (self.consumer / "application.txt").write_bytes(b"Application behavior is outside this task.\n")
        self.commit(self.consumer, "Consumer initial main")
        self.base_sha = git_text("rev-parse", "HEAD", cwd=self.consumer)
        self.consumer_remote = self.base / "consumer.git"
        git("clone", "--quiet", "--bare", self.consumer, self.consumer_remote)
        git("remote", "add", "origin", self.consumer_remote, cwd=self.consumer)
        self.state = {
            "base": str(self.base), "source_remote": str(self.source_remote),
            "source_checkout": str(self.source),
            "consumer_remote": str(self.consumer_remote), "repository": "atyrode/code", "name": "code",
            "pulls": [], "runs": [], "comments": [], "events": [],
            "park_runs": False,
        }
        self.save()
        self.env["AGENT_POLICY_SOURCE_SHA"] = self.source_sha
        self.attempt = 0

    def restore_environment(self):
        os.environ.clear()
        os.environ.update(self.previous)

    def init_repo(self, path):
        git("init", "--quiet", "--initial-branch=main", path)

    def commit(self, path, message):
        git("add", "--all", cwd=path)
        git("commit", "--quiet", "-m", message, cwd=path)

    def save(self):
        self.state_file.write_text(json.dumps(self.state))

    def reload(self):
        self.state = json.loads(self.state_file.read_text())
        return self.state

    def events(self, kind):
        return [event for event in self.state["events"] if event["kind"] == kind]

    def run_sync(self, expected, *, env=None, work=None, repository=None):
        self.save()
        self.attempt += 1
        if work is None:
            work = self.base / f"work-{self.attempt}"
            work.mkdir()
        args = [
            sys.executable, str(SYNC), "--repository", repository or self.state["repository"],
            "--source-checkout", str(self.source), "--work-dir", str(work),
        ]
        proc = subprocess.run(args, env=self.env | (env or {}), capture_output=True, timeout=45)
        self.reload()
        self.assertFalse(self.events("fixture_error"), self.events("fixture_error"))
        self.assertEqual(proc.returncode, expected, f"stdout={proc.stdout!r}\nstderr={proc.stderr!r}\nevents={self.state['events']!r}")
        self.assertNotIn(b"synthetic-not-a-credential", proc.stdout + proc.stderr)
        summary = Path(self.env["GITHUB_STEP_SUMMARY"])
        if summary.exists():
            self.assertNotIn("synthetic-not-a-credential", summary.read_text())
        for comment in self.state["comments"]:
            self.assertNotIn("synthetic-not-a-credential", comment["body"])
        return proc

    def main_bytes(self, path="AGENTS.md"):
        return git("--git-dir", self.consumer_remote, "show", "main:" + path).stdout

    def branch_exists(self):
        return git("--git-dir", self.consumer_remote, "show-ref", "--verify", "refs/heads/" + BRANCH, check=False).returncode == 0

    def seed_candidate(self, payload=NEW, *, draft=True, author="github-actions[bot]", closed=False, extra=False, local=False, source_sha=None, base_sha=None):
        git("checkout", "--quiet", "-b", BRANCH, cwd=self.consumer)
        content = PREFIX + envelope(payload) + SUFFIX
        (self.consumer / "AGENTS.md").write_bytes(content + (b"Unauthorized local text.\n" if local else b""))
        if extra:
            (self.consumer / "application.txt").write_bytes(b"An unauthorized application edit.\n")
        self.commit(self.consumer, "Candidate policy update")
        git("push", "--quiet", "origin", BRANCH, cwd=self.consumer)
        metadata = {"base": base_sha or self.base_sha, "source": source_sha or self.source_sha, "digest": hashlib.sha256(payload).hexdigest()}
        body = "Generated-only policy synchronization.\n\n<!-- agent-policy-sync:v1 " + json.dumps(metadata) + " -->\n"
        pull = make_pull(self.state, body, draft=draft, author=author, closed=closed)
        self.save()
        git("checkout", "--quiet", "main", cwd=self.consumer)
        return pull

    def assert_no_delivery(self):
        self.assertFalse(self.events("merge"))
        self.assertFalse(self.events("dispatch"))
        self.assertEqual(self.main_bytes(), PREFIX + envelope(OLD) + SUFFIX)

    def test_current_main_is_noop_without_branch_pr_or_dispatch(self):
        append_remote_commit(self.state, "consumer_remote", "AGENTS.md", PREFIX + envelope(NEW) + SUFFIX)
        before = ref_sha(self.state)
        self.run_sync(0)
        self.assertEqual(ref_sha(self.state), before)
        self.assertFalse(self.branch_exists())
        for kind in ("create", "merge", "dispatch", "approve"):
            self.assertFalse(self.events(kind))

    def test_corrupt_main_is_refused_without_a_bot_branch(self):
        corrupt = (PREFIX + envelope(OLD) + SUFFIX).replace(b"Preserve evidence", b"Changed evidence")
        append_remote_commit(self.state, "consumer_remote", "AGENTS.md", corrupt)
        self.run_sync(1)
        self.assertEqual(self.main_bytes(), corrupt)
        self.assertFalse(self.branch_exists())
        self.assertFalse(self.events("create"))

    def test_generated_only_merge_leased_cleanup_and_main_dispatch(self):
        self.state["park_runs"] = True
        self.run_sync(0)
        self.assertEqual(self.main_bytes(), PREFIX + envelope(NEW) + SUFFIX)
        self.assertEqual(self.main_bytes("application.txt"), b"Application behavior is outside this task.\n")
        self.assertEqual(len(self.events("create")), 1)
        self.assertTrue(self.events("create")[0]["draft"])
        self.assertEqual([event["method"] for event in self.events("merge")], ["squash"])
        self.assertFalse(self.branch_exists())
        self.assertEqual([event["ref"] for event in self.events("dispatch")], ["main"])
        self.assertEqual(len(self.events("approve")), 2)
        pushes = [event["argv"] for event in self.events("git") if "push" in event["argv"]]
        self.assertTrue(any(any(arg.startswith("--force-with-lease=") for arg in args) for args in pushes))
        changed = git_text("--git-dir", self.consumer_remote, "diff", "--name-only", self.base_sha, "main")
        self.assertEqual(changed, "AGENTS.md")
        before = len(self.events("create"))
        self.run_sync(0)
        self.assertEqual(len(self.events("create")), before)
        self.assertEqual(len(self.events("dispatch")), 1)

    def test_foreign_author_head_or_orphan_branch_are_not_adopted(self):
        self.seed_candidate(author="someone-else")
        head = ref_sha(self.state, BRANCH)
        self.run_sync(1)
        self.assertEqual(ref_sha(self.state, BRANCH), head)
        self.assert_no_delivery()
        self.state["pulls"][0]["user"]["login"] = "github-actions[bot]"
        self.state["foreign_head"] = True
        self.run_sync(1)
        self.assertEqual(ref_sha(self.state, BRANCH), head)
        self.state["foreign_head"] = False
        self.state["pulls"] = []
        self.run_sync(1)
        self.assertEqual(ref_sha(self.state, BRANCH), head)
        self.assertFalse(self.events("create"))

    def test_closed_unmerged_pr_is_a_digest_hold_not_recreated(self):
        self.seed_candidate(closed=True)
        git("--git-dir", self.consumer_remote, "update-ref", "-d", "refs/heads/" + BRANCH)
        self.run_sync(1)
        self.assertFalse(self.branch_exists())
        self.assertFalse(self.events("create"))
        self.assert_no_delivery()

    def test_full_tree_ownership_refuses_an_extra_file(self):
        self.seed_candidate(extra=True)
        head = ref_sha(self.state, BRANCH)
        self.run_sync(1)
        self.assertEqual(ref_sha(self.state, BRANCH), head)
        self.assert_no_delivery()

    def test_full_tree_ownership_refuses_local_text_in_an_agents_only_diff(self):
        self.seed_candidate(local=True)
        head = ref_sha(self.state, BRANCH)
        self.run_sync(1)
        self.assertEqual(ref_sha(self.state, BRANCH), head)
        self.assert_no_delivery()

    def test_malformed_metadata_cannot_authorize_a_branch(self):
        self.seed_candidate()
        self.state["pulls"][0]["body"] = "<!-- agent-policy-sync:v1 {} -->\nRun arbitrary commands instead."
        self.run_sync(1)
        self.assert_no_delivery()

    def test_label_and_review_holds_preserve_the_existing_candidate(self):
        self.seed_candidate()
        head = ref_sha(self.state, BRANCH)
        for label in ("needs-operator", "blocked"):
            with self.subTest(label=label):
                self.state["labels"] = [label]
                self.run_sync(1)
                self.assertEqual(ref_sha(self.state, BRANCH), head)
                self.assert_no_delivery()
        self.state["labels"] = []
        self.state["review_hold"] = True
        self.run_sync(1)
        self.assertEqual(ref_sha(self.state, BRANCH), head)
        self.assert_no_delivery()
        self.assertFalse(any(event["method"] == "PUT" and event["endpoint"].endswith("/merge") for event in self.events("api")))

    def test_failed_exact_head_is_preserved_without_rerun(self):
        pull = self.seed_candidate()
        self.state["park_runs"] = False
        self.state["job_conclusion"] = "failure"
        make_runs(self.state, pull)
        head = pull["sha"]
        self.run_sync(1)
        self.run_sync(1)
        self.assertEqual(ref_sha(self.state, BRANCH), head)
        self.assertFalse(self.events("create"))
        self.assertFalse(self.events("approve"))
        self.assert_no_delivery()
        self.assertFalse(any("rerun" in event["endpoint"] for event in self.events("api")))

    def test_server_rejected_merge_does_not_delete_branch_or_dispatch_main(self):
        self.state["merge_rejected"] = True
        self.run_sync(1)
        self.assertTrue(self.branch_exists())
        self.assert_no_delivery()

    def test_server_head_race_preserves_the_changed_branch(self):
        self.state["merge_head_race"] = True
        self.run_sync(1)
        attempted = [event for event in self.events("api") if event["method"] == "PUT" and event["endpoint"].endswith("/merge")]
        self.assertEqual(len(attempted), 1)
        self.assertNotEqual(ref_sha(self.state, BRANCH), attempted[0]["payload"]["sha"])
        self.assert_no_delivery()

    def test_server_base_race_retains_strict_check_failure_and_concurrent_work(self):
        self.state["merge_base_race"] = True
        self.run_sync(1)
        self.assertEqual(self.main_bytes("concurrent.txt"), b"Reviewed concurrent change.\n")
        self.assertTrue(self.branch_exists())
        self.assert_no_delivery()

    def test_lost_dispatch_response_recovers_existing_run_before_current_noop(self):
        self.state["dispatch_failures"] = 1
        self.state["dispatch_accepted"] = True
        self.run_sync(1)
        self.assertEqual(len(self.events("merge")), 1)
        self.assertEqual(self.main_bytes(), PREFIX + envelope(NEW) + SUFFIX)
        self.run_sync(0)
        self.assertEqual(len(self.events("merge")), 1)
        self.assertEqual(len(self.events("create")), 1)
        self.assertEqual(len(self.events("dispatch")), 1)
        main_runs = [run for run in self.state["runs"] if run["event"] == "workflow_dispatch"]
        self.assertEqual(len(main_runs), 1)
        self.assertEqual(main_runs[0]["head_sha"], ref_sha(self.state))
        self.run_sync(0)
        self.assertEqual(len(self.events("dispatch")), 1)

    def test_merged_pr_with_no_dispatch_recovers_the_missing_phase(self):
        pull = self.seed_candidate(draft=False)
        api_response(self.state, "PUT", f"repos/{self.state['repository']}/pulls/1/merge", {"sha": pull["sha"], "merge_method": "squash"})
        self.assertFalse(self.state["comments"])
        self.run_sync(0)
        self.assertEqual(len(self.events("merge")), 1)
        self.assertEqual(len(self.events("dispatch")), 1)
        self.assertFalse(self.branch_exists())
        self.run_sync(0)
        self.assertEqual(len(self.events("dispatch")), 1)

    def test_completed_failed_main_ci_is_never_rerun_or_reported_current(self):
        self.state["main_conclusion"] = "failure"
        self.run_sync(1)
        self.assertEqual(self.main_bytes(), PREFIX + envelope(NEW) + SUFFIX)
        self.assertEqual(len(self.events("merge")), 1)
        self.run_sync(1)
        self.assertEqual(len(self.events("dispatch")), 1)
        self.assertEqual(len(self.events("merge")), 1)

    def test_recovery_records_a_verified_main_descendant_without_claiming_exact_merge(self):
        pull = self.seed_candidate(draft=False)
        api_response(self.state, "PUT", f"repos/{self.state['repository']}/pulls/1/merge", {"sha": pull["sha"], "merge_method": "squash"})
        merge = ref_sha(self.state)
        append_remote_commit(self.state, "consumer_remote", "descendant.txt", b"Later reviewed main.\n")
        descendant = ref_sha(self.state)
        self.assertNotEqual(merge, descendant)
        self.run_sync(0)
        main_runs = [run for run in self.state["runs"] if run["event"] == "workflow_dispatch"]
        self.assertEqual([run["head_sha"] for run in main_runs], [descendant])
        self.assertTrue(any(descendant in comment["body"] for comment in self.state["comments"]))

    def select_repository(self, name):
        self.state.update({"repository": "atyrode/" + name, "name": name})
        self.env["GITHUB_REPOSITORY"] = self.state["repository"]

    def advance_source(self):
        (self.source / POLICY_PATH).write_bytes(NEXT)
        self.commit(self.source, "Reviewed next policy")
        git("push", "--quiet", self.source_remote, "main", cwd=self.source)
        self.source_sha = git_text("rev-parse", "HEAD", cwd=self.source)
        self.env["AGENT_POLICY_SOURCE_SHA"] = self.source_sha

    def test_babel_requires_its_browser_lane_even_when_other_jobs_pass(self):
        self.select_repository("babel")
        self.state["missing_job"] = "browser"
        self.run_sync(1)
        self.assert_no_delivery()

    def test_manifold_gate_success_preserves_the_main_dispatch_chain(self):
        self.select_repository("manifold")
        self.run_sync(0)
        self.assertEqual(self.main_bytes(), PREFIX + envelope(NEW) + SUFFIX)
        self.assertEqual([event["ref"] for event in self.events("dispatch")], ["main"])

    def test_babel_complete_required_job_set_can_merge(self):
        self.select_repository("babel")
        self.run_sync(0)
        self.assertEqual(self.main_bytes(), PREFIX + envelope(NEW) + SUFFIX)
        self.assertEqual(len(self.events("merge")), 1)

    def test_identical_existing_candidate_preserves_its_head_and_runs(self):
        self.state["park_runs"] = True
        pull = self.seed_candidate()
        runs = make_runs(self.state, pull)
        head = pull["sha"]
        self.run_sync(0)
        self.assertEqual(self.events("merge")[0]["sha"], head)
        self.assertFalse(self.events("create"))
        self.assertEqual({event["run"] for event in self.events("approve")}, {run["id"] for run in runs})
        self.assertFalse(any("commit" in event["argv"] for event in self.events("git")))

    def test_replacing_a_ready_candidate_returns_it_to_draft_before_push(self):
        pull = self.seed_candidate(draft=False)
        previous = pull["sha"]
        self.advance_source()
        self.run_sync(0)
        self.assertEqual(self.main_bytes(), PREFIX + envelope(NEXT) + SUFFIX)
        self.assertNotEqual(self.events("merge")[0]["sha"], previous)
        draft_index = next(index for index, event in enumerate(self.state["events"]) if event["kind"] == "draft")
        update_index = next(index for index, event in enumerate(self.state["events"]) if event["kind"] == "git" and "push" in event["argv"])
        self.assertLess(draft_index, update_index)
        self.assertEqual(len(self.state["pulls"]), 1)
        self.assertFalse(self.events("create"))

    def test_expected_head_lease_refuses_a_concurrent_branch_push(self):
        self.seed_candidate(draft=False)
        self.advance_source()
        self.state["push_race"] = True
        self.run_sync(1)
        self.assertTrue(self.state["push_race_fired"])
        self.assert_no_delivery()

    def test_changed_canonical_digest_invalidates_premerge_evidence(self):
        self.state["park_runs"] = True
        self.state["source_race"] = True
        self.run_sync(1)
        self.assertTrue(self.state["source_race_fired"])
        self.assert_no_delivery()

    def test_changed_main_invalidates_the_tested_integration_target(self):
        self.state["park_runs"] = True
        self.state["base_race"] = True
        self.run_sync(1)
        self.assertTrue(self.state["base_race_fired"])
        self.assert_no_delivery()
        self.assertEqual(self.main_bytes("concurrent.txt"), b"Reviewed concurrent change.\n")

    def test_required_protection_failure_is_not_overridden_by_green_core_runs(self):
        self.state["protection_blocked"] = True
        self.run_sync(1)
        self.assert_no_delivery()

    def test_new_hold_during_ci_stops_before_merge_and_is_not_cleared(self):
        self.state["park_runs"] = True
        self.state["hold_after_approval"] = True
        self.run_sync(1)
        self.assertEqual(self.state["labels"], ["blocked"])
        self.assert_no_delivery()
        self.assertFalse(any(event["method"] == "PUT" and event["endpoint"].endswith("/merge") for event in self.events("api")))

    def test_only_exact_owned_pr_runs_are_approved(self):
        self.state["park_runs"] = True
        pull = self.seed_candidate()
        wanted = make_runs(self.state, pull)
        wanted_ids = {run["id"] for run in wanted}
        for mutation in (
            {"event": "workflow_dispatch"},
            {"head_sha": self.base_sha},
            {"workflow_id": 99, "workflow": "unrelated.yml", "path": ".github/workflows/unrelated.yml"},
        ):
            unrelated = json.loads(json.dumps(wanted[0]))
            unrelated.update(mutation)
            unrelated["id"] = 100 + len(self.state["runs"])
            self.state["runs"].append(unrelated)
        self.run_sync(0)
        self.assertEqual({event["run"] for event in self.events("approve")}, wanted_ids)

    def test_run_identity_mismatch_is_refused_before_any_approval(self):
        pull = self.seed_candidate()
        original = json.loads(json.dumps(make_runs(self.state, pull)))
        mutations = (
            {"head_branch": "unrelated"},
            {"head_repository": {"full_name": "outsider/code", "fork": True}},
            {"repository": {"full_name": "outsider/code"}},
            {"pull_requests": [{"number": 99}]},
            {"path": ".github/workflows/unrelated.yml"},
            {"run_attempt": 2},
        )
        for mutation in mutations:
            with self.subTest(identity=mutation):
                self.state["runs"] = json.loads(json.dumps(original))
                self.state["runs"][0].update(mutation)
                self.run_sync(1)
                self.assertFalse(self.events("approve"))
                self.assert_no_delivery()

    def test_ambiguous_same_head_runs_are_not_arbitrarily_approved(self):
        pull = self.seed_candidate()
        make_runs(self.state, pull)
        make_runs(self.state, pull)
        self.run_sync(1)
        self.assertFalse(self.events("approve"))
        self.assert_no_delivery()

    def test_non_success_required_jobs_never_become_merge_evidence(self):
        pull = self.seed_candidate()
        self.state["park_runs"] = False
        make_runs(self.state, pull)
        for conclusion in ("skipped", "cancelled", "timed_out", None):
            with self.subTest(conclusion=conclusion):
                for run in self.state["runs"]:
                    if run["event"] == "pull_request":
                        run["conclusion"] = "success"
                        run["jobs"][0]["conclusion"] = conclusion
                self.run_sync(1)
                self.assert_no_delivery()
        self.assertEqual(ref_sha(self.state, BRANCH), pull["sha"])

    def test_recorded_source_must_be_reachable_from_canonical_main(self):
        git("checkout", "--quiet", "--detach", self.old_source_sha, cwd=self.source)
        (self.source / POLICY_PATH).write_bytes(NEW)
        self.commit(self.source, "Unreviewed side source")
        side = git_text("rev-parse", "HEAD", cwd=self.source)
        git("checkout", "--quiet", "main", cwd=self.source)
        self.seed_candidate(source_sha=side)
        self.run_sync(1)
        self.assert_no_delivery()

    def test_recorded_base_must_be_an_ancestor_of_reviewed_main(self):
        git("checkout", "--quiet", "--detach", self.base_sha, cwd=self.consumer)
        (self.consumer / "unreviewed.txt").write_bytes(b"Side-branch work.\n")
        self.commit(self.consumer, "Unreviewed side base")
        side = git_text("rev-parse", "HEAD", cwd=self.consumer)
        git("push", "--quiet", "origin", side + ":refs/heads/unreviewed", cwd=self.consumer)
        git("checkout", "--quiet", "main", cwd=self.consumer)
        self.seed_candidate(base_sha=side)
        self.run_sync(1)
        self.assert_no_delivery()

    def test_invalid_invocation_never_creates_a_consumer_candidate(self):
        for changes in (
            {"GITHUB_EVENT_NAME": "pull_request"},
            {"GITHUB_REF": "refs/heads/not-main"},
            {"GITHUB_REPOSITORY": "outsider/code"},
            {"GH_TOKEN": ""},
        ):
            with self.subTest(environment=changes):
                self.run_sync(2, env=changes)
                self.assertFalse(self.branch_exists())
                self.assertFalse(self.events("create"))
        self.run_sync(2, repository="outsider/code")
        occupied = self.base / "occupied"
        occupied.mkdir()
        unrelated = occupied / "keep"
        unrelated.write_bytes(b"Do not clean unrelated data.\n")
        self.run_sync(2, work=occupied)
        self.assertEqual(unrelated.read_bytes(), b"Do not clean unrelated data.\n")
        nested = occupied / "consumer"
        nested.mkdir()
        nested_file = nested / "keep"
        nested_file.write_bytes(b"This preexisting directory is not run-owned.\n")
        self.run_sync(2, work=occupied)
        self.assertEqual(nested_file.read_bytes(), b"This preexisting directory is not run-owned.\n")

    def test_dirty_source_is_refused_instead_of_running_unreviewed_helpers(self):
        with (self.source / "ci/agent-policy.py").open("ab") as output:
            output.write(b"\n# An uncommitted source change.\n")
        self.run_sync(1)
        self.assertFalse(self.branch_exists())
        self.assertFalse(self.events("create"))

    def test_workflow_source_revision_mismatch_is_refused(self):
        self.run_sync(1, env={"AGENT_POLICY_SOURCE_SHA": "0" * 40})
        self.assertFalse(self.branch_exists())
        self.assertFalse(self.events("create"))

    def test_source_fetch_failure_cannot_turn_cached_current_bytes_green(self):
        append_remote_commit(self.state, "consumer_remote", "AGENTS.md", PREFIX + envelope(NEW) + SUFFIX)
        self.state["source_fetch_failure"] = True
        self.run_sync(1)
        self.assertFalse(self.branch_exists())
        self.assertFalse(self.events("create"))

    def test_obsolete_owned_pr_closes_only_when_its_generated_change_is_on_main(self):
        self.seed_candidate()
        append_remote_commit(self.state, "consumer_remote", "AGENTS.md", PREFIX + envelope(NEW) + SUFFIX)
        self.run_sync(0)
        self.assertEqual(self.state["pulls"][0]["state"], "closed")
        self.assertFalse(self.state["pulls"][0]["merged"])
        self.assertFalse(self.branch_exists())
        self.assertFalse(self.events("merge"))
        self.assertFalse(self.events("dispatch"))
        self.run_sync(0)
        self.assertEqual(len(self.state["pulls"]), 1)
        self.assertFalse(self.events("create"))

    def test_reopening_the_held_pr_resumes_it_without_creating_another(self):
        pull = self.seed_candidate(closed=True)
        head = pull["sha"]
        git("--git-dir", self.consumer_remote, "update-ref", "-d", "refs/heads/" + BRANCH)
        self.run_sync(1)
        self.state["pulls"][0]["state"] = "open"
        self.state["pulls"][0]["closed_at"] = None
        git("--git-dir", self.consumer_remote, "update-ref", "refs/heads/" + BRANCH, head)
        make_runs(self.state, self.state["pulls"][0])
        self.run_sync(0)
        self.assertEqual(len(self.state["pulls"]), 1)
        self.assertFalse(self.events("create"))
        self.assertEqual(self.events("merge")[0]["sha"], head)

    def test_unrelated_canonical_commit_does_not_replace_a_current_candidate(self):
        pull = self.seed_candidate()
        make_runs(self.state, pull)
        head = pull["sha"]
        (self.source / "unrelated.txt").write_bytes(b"An unrelated reviewed source change.\n")
        self.commit(self.source, "Unrelated reviewed source change")
        git("push", "--quiet", self.source_remote, "main", cwd=self.source)
        self.env["AGENT_POLICY_SOURCE_SHA"] = git_text("rev-parse", "HEAD", cwd=self.source)
        self.run_sync(0)
        self.assertEqual(self.events("merge")[0]["sha"], head)
        self.assertFalse(self.events("create"))
        self.assertFalse(any("commit" in event["argv"] for event in self.events("git")))

    def test_historical_source_does_not_execute_its_historical_renderer(self):
        helper = self.source / "ci/agent-policy.py"
        trusted = helper.read_bytes()
        helper.write_bytes(b"raise RuntimeError('Historical helpers must never execute')\n")
        self.commit(self.source, "Historical executable is not trusted for reconstruction")
        historical = git_text("rev-parse", "HEAD", cwd=self.source)
        helper.write_bytes(trusted)
        self.advance_source()
        self.seed_candidate(source_sha=historical)
        self.run_sync(0)
        self.assertEqual(self.main_bytes(), PREFIX + envelope(NEXT) + SUFFIX)

    def test_non_strict_protection_cannot_qualify_a_green_candidate(self):
        self.state["non_strict"] = True
        self.run_sync(1)
        self.assert_no_delivery()


if __name__ == "__main__":
    unittest.main()

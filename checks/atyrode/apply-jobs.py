"""Drive real terminal input and process cancellation around the apply worker."""

import json
import os
from pathlib import Path
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time

library = Path(sys.argv[1]).resolve()
bash = sys.argv[2]
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    manager = root / "systemctl"
    manager.write_text(f"#!{sys.executable}\n" + '''import json,os,signal,sys
from pathlib import Path
root=Path(os.environ['FIXTURE_ROOT'])
unit=sys.argv[-1]
record=root/unit
if 'is-active' in sys.argv:
    if not record.exists(): sys.exit(4)
    try: os.kill(int(record.read_text()),0)
    except ProcessLookupError: sys.exit(3)
    sys.exit(0)
if 'stop' in sys.argv:
    pid=int(record.read_text())
    os.killpg(pid,signal.SIGTERM)
    (root/'stopped').write_text(unit)
    record.unlink()
    sys.exit(0)
sys.exit(64)
''')
    manager.chmod(0o755)
    env = dict(os.environ, HOME=str(root), XDG_STATE_HOME=str(root / "state"), FIXTURE_ROOT=str(root), NO_COLOR="1")
    setup = f'''
set -euo pipefail
. {shlex.quote(str(library / 'narrate.sh'))}
. {shlex.quote(str(library / 'apply-job.sh'))}
EX_USAGE=64 EX_DATAERR=65 EX_NOINPUT=66 EX_UNAVAILABLE=69 EX_SOFTWARE=70
interactive() {{ [[ -t 0 ]]; }}
die() {{ printf '%s\\n' "$2" >&2; exit "$1"; }}
guard_production_mutation() {{ :; }}
start_run_log() {{ :; }}
apply_systemctl_command() {{ printf '%s\\n' {shlex.quote(str(manager))}; }}
apply_config() {{
  plan_steps 'Activate fixture' 'Review fixture'
  step_begin 'Activate fixture'
  apply_job_activated
  step_ok
  step_begin 'Review fixture'
  confirm 'Keep this fixture?' || true
  step_ok
}}
'''
    jobs = root / "state/atyrode/apply-jobs"
    jobs.mkdir(parents=True)
    children = []

    def start_job(number):
        job = f"1-{os.getpid()}-{number}"
        directory = jobs / job
        directory.mkdir()
        unit = f"atyrode-apply-{job}.service"
        (directory / "metadata.json").write_text(json.dumps({"jobId": job, "unit": unit, "live": True, "originTty": "fixture terminal"}))
        (directory / "output.log").touch()
        terminal, slave = os.openpty()
        try:
            process = subprocess.Popen(
                [bash, "-c", setup + '\nrun_apply_job_worker "$1"', "fixture", str(directory)],
                env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
            )
        finally:
            os.close(slave)
        children.append((process, terminal))
        (root / unit).write_text(str(process.pid))
        transcript = b""
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if select.select([terminal], [], [], 0.05)[0]:
                transcript += os.read(terminal, 65536)
            if b"Keep this fixture?" in transcript:
                return job, directory, process, terminal, transcript
        raise AssertionError(f"fixture never reached terminal prompt: {transcript!r}")

    def status(job, *arguments, check=True):
        return subprocess.run([bash, "-c", setup + '\ncmd_apply_status "$@"', "fixture", job, *arguments],
                              env=env, text=True, capture_output=True, check=check, timeout=10)

    try:
        job, directory, process, terminal, transcript = start_job(1)
        observed = json.loads(status(job, "--json").stdout)
        assert observed["phase"] == "waiting", observed
        assert observed["progress"]["step"] == "Review fixture", observed
        assert observed["progress"]["activationCompleted"] is True, observed
        text = status(job).stderr
        assert "fixture terminal" in text and f"{job} --cancel" in text, text
        assert b"2/2 Review fixture" in transcript, transcript
        status(job, "--cancel")
        result = process.wait(timeout=10)
        assert result == -signal.SIGTERM, result
        cancelled = json.loads(status(job, "--json", check=False).stdout)
        assert cancelled["phase"] == "cancelled" and cancelled["result"]["activationCompleted"], cancelled
        children.remove((process, terminal))
        os.close(terminal)

        next_job, next_directory, next_process, next_terminal, _ = start_job(2)
        (root / "stopped").unlink()
        status(job, "--cancel")
        assert not (root / "stopped").exists(), "historical cancellation stopped a newer job"
        os.write(next_terminal, b"n\n")
        result = next_process.wait(timeout=10)
        assert result == 0, result
        assert json.loads((next_directory / "result.json").read_text())["phase"] == "succeeded"
        children.remove((next_process, next_terminal))
        os.close(next_terminal)
        print("apply job PTY: waiting status, explicit cancellation, stale-id safety, and subsequent completion passed")
    finally:
        for process, terminal in children:
            try:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
            except ProcessLookupError:
                pass
            os.close(terminal)

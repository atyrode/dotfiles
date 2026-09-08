#!/usr/bin/env python3
"""Check managed launch boundaries against the pinned binary's live CLI metadata."""
import argparse
from pathlib import Path
import os
import re
import shlex
import subprocess
import tempfile


def run(binary, *args):
    return subprocess.run([binary, *args], text=True, capture_output=True, timeout=30, check=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omp", required=True)
    parser.add_argument("--managed-stub", required=True)
    parser.add_argument("--configured", type=Path, required=True)
    parser.add_argument("--grammar", type=Path, required=True)
    args = parser.parse_args()
    grammar = args.grammar.read_text()
    groups = {}
    for name in ("required", "optional", "boolean", "subcommands"):
        variable = "omp_subcommands" if name == "subcommands" else f"omp_{name}_flags"
        match = re.search(rf"{variable}=\((.*?)\)", grammar, re.S)
        assert match, f"Missing grammar group: {name}"
        groups[name] = set(shlex.split(match.group(1)))
    completion = run(args.omp, "completions", "bash")
    root = completion.split("_omp_root() {", 1)[1].split("\n}", 1)[0]
    advertised = set(re.findall(r'compgen -W "([^"\n]*)" -- "\$cur"', root)[-1].split())
    flags = {word for word in advertised if word.startswith("-")}
    values = {flag for arm in re.findall(r"^\s+(-[^\n]*)\)\s*$", root, re.M) for flag in arm.split("|")}
    missing = flags - groups["required"] - groups["optional"] - groups["boolean"]
    assert not missing, f"New upstream flags need wrapper review: {sorted(missing)}"
    assert values <= groups["required"] | groups["optional"], f"Upstream value arity changed: {sorted(values - groups['required'] - groups['optional'])}"
    assert flags - values <= groups["boolean"], f"Upstream boolean arity changed: {sorted(flags - values - groups['boolean'])}"
    commands = advertised - flags
    assert commands <= groups["subcommands"], f"New upstream commands need wrapper review: {sorted(commands - groups['subcommands'])}"
    # Every maintained string flag must protect both subcommand-looking and
    # policy/config-looking values. Inspect consumer argv, not source wiring.
    for flag in sorted(groups["required"] - {"--config", "--alias"}):
        for value in ("models", "--config", "--no-extensions"):
            if flag == "--profile" and value.startswith("-"):
                continue  # Profile name validation intentionally precedes launch.
            actual = run(args.managed_stub, flag, value).splitlines()
            assert actual[-2:] == [flag, value], (flag, value, actual)
            assert actual[0] == "--extension", (flag, value, actual)
    for prefix in (("--prewalk",), ("--external-thinking=false",), ("--no-prewalk",)):
        actual = run(args.managed_stub, *prefix, "models", "--json").splitlines()
        assert actual == [*prefix, "models", "--json"], actual
    actual = run(args.managed_stub, "launch", "--system-prompt", "models").splitlines()
    assert actual[0] == "--extension" and actual[-2:] == ["--system-prompt", "models"], actual
    actual = run(args.managed_stub, "--", "--no-extensions", "--config", "literal").splitlines()
    assert actual[-4:] == ["--", "--no-extensions", "--config", "literal"], actual
    # Bootstrap can install shell aliases before normal launch parsing. Exercise
    # the real restricted launchers with state entirely confined to this fixture.
    for command in ("ompu", "omp-analysis"):
        for options in (
            ("--plan", "--alias=reviewproof"),
            ("--plan", "--alias", "reviewproof"),
            ("--plan", "--profile=other", "--version"),
            ("--plan", "--profile", "other", "--version"),
        ):
            with tempfile.TemporaryDirectory(prefix="omp-bootstrap-") as temporary:
                home = Path(temporary) / "home"
                outside = Path(temporary) / "outside"
                home.mkdir()
                outside.mkdir()
                result = subprocess.run(
                    [str(args.configured / "bin" / command), *options],
                    env={"HOME": str(home), "PATH": os.defpath,
                         "SHELL": "/bin/zsh", "ZDOTDIR": str(outside)},
                    cwd=home, text=True, capture_output=True, timeout=30,
                )
                assert result.returncode == 2, (command, options, result.returncode)
                assert not (outside / ".zshrc").exists(), "bootstrap wrote outside isolated HOME"
                assert not (home / ".local/state/atyrode").exists(), "refusal occurred after state setup"
    print("Pinned CLI metadata and managed argv boundaries agree")


if __name__ == "__main__":
    main()

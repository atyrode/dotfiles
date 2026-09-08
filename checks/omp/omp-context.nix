{
  lib,
  pkgs,
  homeConfigs,
}:

let
  # Only instruction inputs affect this fixture, not unrelated documentation.
  src = lib.fileset.toSource {
    root = ../../.;
    fileset = lib.fileset.unions [
      ../../AGENTS.md
      ../../modules/home/agents/AGENTS.md
      ../../modules/home/agents/engineering.md
    ];
  };
  adapterNames = [
    ".omp/agent/AGENTS.md"
    ".claude/CLAUDE.md"
    ".codex/AGENTS.md"
  ];
  homes = lib.mapAttrsToList (
    name: home:
    let
      inherit (home) config;
    in
    {
      inherit name;
      homeDirectory = config.home.homeDirectory;
      configHome = config.xdg.configHome;
      activation = pkgs.writeText "${name}-render-agent-context" config.home.activation.renderAgentContext.data;
      adapters = map (
        adapter:
        let
          file = config.home.file.${adapter};
        in
        {
          inherit (file) target source enable;
        }
      ) adapterNames;
    }
  ) homeConfigs;
  manifest = pkgs.writeText "agent-context-deployment.json" (builtins.toJSON homes);
  deploymentCheck = pkgs.writeText "check-agent-context-deployment.py" ''
    import datetime
    import importlib.util
    import json
    import os
    from pathlib import Path
    import re
    import signal
    import subprocess
    import tempfile
    import time

    spec = importlib.util.spec_from_file_location("context_check", "${../../ci/check-agent-context.py}")
    check = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(check)
    source = check.document("${src}/modules/home/agents/AGENTS.md")
    root = check.document("${src}/AGENTS.md")
    common = check.document("${src}/modules/home/agents/engineering.md")
    homes = json.loads(Path("${manifest}").read_text())
    check.require(bool(homes), "no evaluated Home Manager configuration supplied")
    stamp = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")

    def run(argv, home, config_home=None):
        process = subprocess.Popen(argv, env=check.clean_environment(home, config_home), cwd=home,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=30)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)
            raise
        check.require(process.returncode == 0, "context assembly failed: " + stderr.decode())
        return stdout

    def verify_document(path, since):
        content = check.document(path)
        check.require(content.startswith(source) and content.count(source) == 1,
                      "rendered context does not contain the exact current personal source once")
        provenance = content[len(source):]
        matches = list(stamp.finditer(provenance))
        check.require(len(matches) == 1, "rendered context lacks unique generation provenance")
        timestamp = datetime.datetime.strptime(matches[0].group(), "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp()
        check.require(since - 1 <= timestamp <= time.time() + 1, "context generation timestamp is stale")
        check.require(path.is_file() and not path.is_symlink(), "rendered source is not a regular file")
        check.require(path.stat().st_mode & 0o777 == 0o644, "rendered source has wrong permissions")
        check.require(common not in content, "personal document duplicates repository engineering")
        return content, stamp.sub("<generation-time>", content)

    def relocate(path, old_home, new_home):
        path = Path(path)
        check.require(path.is_absolute() and path.is_relative_to(old_home),
                      "deployment path is outside the declared home: " + str(path))
        return new_home / path.relative_to(old_home)

    def adapter_target(source_path, old_home, new_home):
        # Follow actual evaluated mkOutOfStoreSymlink sources, but intercept
        # their declared-home target BEFORE any lookup against the real home.
        current = Path(source_path)
        for _ in range(16):
            if current.is_relative_to(old_home):
                return relocate(current, old_home, new_home)
            check.require(current.is_absolute() and str(current).startswith("/nix/store/"),
                          "adapter source escaped Nix store or declared home")
            check.require(current.is_symlink(), "adapter source no longer targets writable personal context")
            target = Path(os.readlink(current))
            current = target if target.is_absolute() else current.parent / target
        raise AssertionError("adapter source contains a symlink loop")

    with tempfile.TemporaryDirectory(prefix="context-deployment-") as temporary:
        base = Path(temporary)
        reference_home = base / "reference"
        check.clean_environment(reference_home)
        started = time.time()
        run(["${lib.getExe pkgs.atyrode}", "context", "render"], reference_home)
        reference_path = reference_home / ".config/agents/AGENTS.md"
        _, reference = verify_document(reference_path, started)
        for item in homes:
            home = base / item["name"]
            check.clean_environment(home)
            old_home = Path(item["homeDirectory"])
            config_home = relocate(item["configHome"], old_home, home)
            # Derive the output root from evaluated XDG configuration. The
            # render command owns its document name, checked via native readers.
            expected = config_home / "agents/AGENTS.md"
            fragment = Path(item["activation"]).read_text().replace(str(old_home), str(home))
            check.require({adapter["target"] for adapter in item["adapters"]} == set(check.ADAPTERS),
                          "Home Manager changed a native instruction adapter destination")
            for adapter in item["adapters"]:
                check.require(adapter["enable"], "Home Manager disabled an instruction adapter")
                target = adapter_target(adapter["source"], old_home, home)
                check.require(target == expected, "Home Manager adapter points at the wrong document")
                link = home / adapter["target"]
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(target)

            # First activation must create the source; another activation must
            # replace stale bytes while the existing adapter links stay valid.
            for stale in (False, True):
                if stale:
                    check.put(expected, "obsolete personal context fixture\n")
                started = time.time()
                run(["${lib.getExe pkgs.bash}", "-euc", fragment], home, config_home)
                personal, normalized = verify_document(expected, started)
                check.require(normalized == reference,
                              "HM activation differs from the actual packaged context writer")
                for adapter in item["adapters"]:
                    link = home / adapter["target"]
                    check.require(link.samefile(expected) and link.read_bytes() == expected.read_bytes(),
                                  "HM adapter does not expose the current rendered source")

            repository = home / "repository"
            check.put(repository / "AGENTS.md", root)
            (repository / ".git").mkdir()
            for executable, managed in (("${lib.getExe pkgs.omp}", False),
                                        ("${pkgs.omp-configured}/bin/omp-managed", True)):
                with check.Rpc(executable, home, repository, managed=managed, config_home=config_home) as rpc:
                    check.check_prompt(rpc.prompt(), [("activated personal", personal), ("root", root)],
                                       common=common)
            print("ok: actual context activation and adapters: " + item["name"], flush=True)

        # The same reusable runner used by consumer policy actions; here its
        # personal input is an actual packaged render, not a prose fixture.
        check.exercise("${lib.getExe pkgs.omp}", root, check.document(reference_path), common)
        check.exercise("${pkgs.omp-configured}/bin/omp-managed", root,
                       check.document(reference_path), common, managed=True)
  '';
in
pkgs.runCommand "check-omp-context"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.gitMinimal
      pkgs.bash
    ];
  }
  ''
    python3 ${deploymentCheck}
    mkdir "$out"
  ''

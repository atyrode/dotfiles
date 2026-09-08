{
  pkgs,
}:

pkgs.runCommand "check-bun-fd-ownership-${pkgs.stdenv.hostPlatform.system}" { } ''
    cat > "$TMPDIR/fd-ownership.ts" <<'EOF'
    import { closeSync, fstatSync, openSync } from "node:fs";

    const shell = ${builtins.toJSON pkgs.runtimeShell};

    function assertOpen(fd: number, phase: string): void {
      try {
        fstatSync(fd);
      } catch (error) {
        throw new Error(`''${phase}: Bun closed the caller-owned descriptor`, { cause: error });
      }
    }

    function assertExited(status: number | null, phase: string): void {
      if (status !== 0) throw new Error(`''${phase}: child exited with ''${status}`);
    }

    const fd = openSync("/dev/null", "r");
    try {
      const sync = Bun.spawnSync([shell, "-c", "test -r /dev/fd/3"], {
        stdio: ["ignore", "ignore", "ignore", fd],
      });
      assertExited(sync.exitCode, "spawnSync");
      Bun.gc(true);
      assertOpen(fd, "spawnSync");

      await (async () => {
        const child = Bun.spawn([shell, "-c", "test -r /dev/fd/3"], {
          stdio: ["ignore", "ignore", "ignore", fd],
        });
        assertExited(await child.exited, "spawn");
      })();
      Bun.gc(true);
      assertOpen(fd, "spawn");
    } finally {
      closeSync(fd);
    }
  EOF
    ${pkgs.bun}/bin/bun "$TMPDIR/fd-ownership.ts"
    mkdir "$out"
''

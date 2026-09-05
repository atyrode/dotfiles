import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Test the downloaded native artifact, not an interpreted copy of its source.
// The peer, credentials, terminal workload and both processes are disposable.
const binary = process.argv[2]!;
const split = process.argv[3] === "1";
const directory = mkdtempSync(join(tmpdir(), "manifold-agent-smoke-"));
const tokenPath = join(directory, "machine.token");
const token = "disposable-smoke-token";
const terminalId = "00000000-0000-4000-8000-000000000003";
writeFileSync(tokenPath, token, { mode: 0o600 });
let connections = 0;
let activeSocket: Bun.ServerWebSocket<unknown> | undefined;
let failure: unknown;
let terminalOutput = "";
const inventories: Array<Array<{ terminalId: string; alive: boolean }>> = [];
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(request, listener) {
    if (new URL(request.url).pathname === "/ws/machine" && listener.upgrade(request)) return;
    return new Response("not found", { status: 404 });
  },
  websocket: {
    message(socket, data) {
      try {
        const message = JSON.parse(String(data));
        if (message.type === "hello") {
          assert.equal(message.name, "disposable-native-spoke");
          assert.equal(message.token, token);
          activeSocket = socket;
          connections++;
          inventories.push(message.terminals);
          socket.send(JSON.stringify({
            type: "welcome",
            machineId: "00000000-0000-4000-8000-000000000001",
            serverEpoch: "00000000-0000-4000-8000-000000000002",
          }));
        } else if (message.type === "output") {
          terminalOutput += Buffer.from(message.data, "base64").toString("utf8");
        } else if (message.type === "create_error") {
          throw new Error(`disposable workload failed: ${message.message}`);
        }
      } catch (error) {
        failure = error;
      }
    },
  },
});
const common = {
  PATH: process.env.PATH,
  HOME: directory,
  ...(split ? { MANIFOLD_TERMINAL_HOST_SOCKET: join(directory, "terminal-host.sock") } : {}),
};
let log = "";
const collected: Promise<void>[] = [];
const processes: Bun.Subprocess<"ignore", "pipe", "pipe">[] = [];
function launch(owner = false) {
  const process = Bun.spawn(owner ? [binary, "--terminal-host"] : [binary], {
    env: owner ? common : {
      ...common,
      MANIFOLD_SERVER_URL: `http://127.0.0.1:${server.port}`,
      MANIFOLD_MACHINE_NAME: "disposable-native-spoke",
      MANIFOLD_MACHINE_TOKEN_FILE: tokenPath,
    },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  processes.push(process);
  for (const stream of [process.stdout, process.stderr]) {
    collected.push((async () => {
      const decoder = new TextDecoder();
      for await (const chunk of stream) log += decoder.decode(chunk, { stream: true });
    })());
  }
  return process;
}
async function until(predicate: () => boolean, reason: string) {
  const deadline = Date.now() + 15_000;
  while (!predicate()) {
    if (failure) throw failure;
    if (Date.now() >= deadline) throw new Error(reason);
    await Bun.sleep(25);
  }
}
function send(value: unknown) {
  assert.ok(activeSocket, "no connected disposable agent");
  activeSocket.send(JSON.stringify(value));
}
async function stop(process: Bun.Subprocess, signal: "SIGTERM" | "SIGKILL") {
  if (process.exitCode !== null || process.signalCode !== null) return;
  process.kill(signal);
  const force = setTimeout(() => process.kill("SIGKILL"), 5_000);
  await process.exited;
  clearTimeout(force);
}
try {
  if (split) launch(true);
  let agent = launch();
  await until(() => connections === 1 && log.includes('"evt":"welcome"'), "agent handshake timed out");
  if (split) {
    send({
      type: "create", terminalId, cols: 80, rows: 24, env: {},
      program: { argv: ["/bin/sh", "-c", "printf 'OWNER_PID:%s\\n' \"$$\"; while IFS= read -r line; do printf 'REPLY:%s:%s\\n' \"$$\" \"$line\"; done"] },
    });
    await until(() => /OWNER_PID:(\d+)/.test(terminalOutput), "terminal did not start");
    const workloadPid = terminalOutput.match(/OWNER_PID:(\d+)/)![1]!;
    for (const signal of ["SIGTERM", "SIGKILL"] as const) {
      const count = connections;
      await stop(agent, signal);
      agent = launch();
      await until(() => connections === count + 1, `agent did not reconnect after ${signal}`);
      assert.ok(inventories.at(-1)?.some((item) => item.terminalId === terminalId && item.alive), "replacement lost its live terminal inventory");
      const marker = `after-${signal}`;
      send({ type: "input", terminalId, data: Buffer.from(`${marker}\n`).toString("base64") });
      await until(() => terminalOutput.includes(`REPLY:${workloadPid}:${marker}`), `same workload did not answer after ${signal}`);
    }
    send({ type: "kill", terminalId });
  }
  assert.ok(!log.includes(token), "agent exposed its token in logs");
  console.log(split
    ? "native transport SIGTERM and SIGKILL preserved terminal identity, workload PID and usable I/O"
    : "legacy native agent launched and authenticated; terminal preservation is not supported by this pin");
} catch (error) {
  console.error(log.replaceAll(token, "[redacted]"));
  throw error;
} finally {
  for (const process of processes.reverse()) await stop(process, "SIGTERM");
  await Promise.all(collected);
  server.stop(true);
  rmSync(directory, { recursive: true, force: true });
}

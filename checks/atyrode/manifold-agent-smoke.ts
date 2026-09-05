import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Evaluating a Darwin closure cannot establish that its downloaded Mach-O
// executable still launches. Exercise the released artifact on each native
// runner with disposable credentials and a loopback protocol peer.
const directory = mkdtempSync(join(tmpdir(), "manifold-agent-smoke-"));
const tokenPath = join(directory, "machine.token");
const token = "disposable-smoke-token";
writeFileSync(tokenPath, token, { mode: 0o600 });
const hello = Promise.withResolvers<void>();
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
        assert.equal(message.type, "hello");
        assert.equal(message.name, "disposable-native-spoke");
        assert.equal(message.token, token);
        socket.send(JSON.stringify({
          type: "welcome",
          machineId: "00000000-0000-4000-8000-000000000001",
          serverEpoch: "00000000-0000-4000-8000-000000000002",
        }));
        hello.resolve();
      } catch (error) {
        hello.reject(error);
      }
    },
  },
});
const agent = Bun.spawn([process.argv[2]!], {
  env: {
    PATH: process.env.PATH,
    HOME: directory,
    MANIFOLD_SERVER_URL: `http://127.0.0.1:${server.port}`,
    MANIFOLD_MACHINE_NAME: "disposable-native-spoke",
    MANIFOLD_MACHINE_TOKEN_FILE: tokenPath,
  },
  stdout: "pipe",
  stderr: "pipe",
});
let output = "";
async function collect(stream: ReadableStream<Uint8Array>) {
  const decoder = new TextDecoder();
  for await (const chunk of stream) output += decoder.decode(chunk, { stream: true });
}
const collected = Promise.all([collect(agent.stdout), collect(agent.stderr)]);
const timedOut = Promise.withResolvers<never>();
const deadline = setTimeout(() => timedOut.reject(new Error("agent handshake timed out")), 15_000);
try {
  await Promise.race([
    hello.promise,
    agent.exited.then((code) => { throw new Error(`agent exited before hello: ${code}`); }),
    timedOut.promise,
  ]);
  for (let attempt = 0; attempt < 200 && !output.includes('"evt":"welcome"'); attempt++) {
    await Bun.sleep(25);
  }
  assert.ok(output.includes('"evt":"welcome"'), "agent did not accept the peer's welcome");
  assert.ok(!output.includes(token), "agent exposed its token in logs");
  console.log("native agent launched, authenticated from its token file, and accepted welcome");
} catch (error) {
  console.error(output.replaceAll(token, "[redacted]"));
  throw error;
} finally {
  clearTimeout(deadline);
  agent.kill("SIGTERM");
  const force = setTimeout(() => agent.kill("SIGKILL"), 5_000);
  await agent.exited;
  clearTimeout(force);
  await collected;
  server.stop(true);
  rmSync(directory, { recursive: true, force: true });
}

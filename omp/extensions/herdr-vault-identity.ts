import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { createConnection } from "node:net";

const socketPath = process.env.HERDR_SOCKET_PATH;
const paneId = process.env.HERDR_PANE_ID;
const vaultBroker = process.env.OMP_AUTH_BROKER_URL?.trim() ?? "";
const source = "atyrode:vault-identity";

const enabled =
	process.env.HERDR_ENV === "1" && !!socketPath && !!paneId && vaultBroker.length > 0;

let requestQueue = Promise.resolve();

function sendRequestAttempt(request: unknown, timeoutMs: number): Promise<boolean> {
	if (!enabled) return Promise.resolve(true);

	const { promise, resolve } = Promise.withResolvers<boolean>();
	let done = false;
	let timeout: NodeJS.Timeout | undefined;
	const finish = (delivered: boolean) => {
		if (done) return;
		done = true;
		clearTimeout(timeout);
		socket.destroy();
		resolve(delivered);
	};

	const socket = createConnection(socketPath!);
	socket.on("error", () => finish(false));
	socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
	socket.on("data", () => finish(true));
	socket.on("end", () => finish(false));
	timeout = setTimeout(() => finish(false), timeoutMs);
	timeout.unref?.();
	return promise;
}

async function sendRequestNow(request: unknown): Promise<void> {
	if (await sendRequestAttempt(request, 500)) return;
	await sendRequestAttempt(request, 1500);
}

function sendRequest(request: unknown): Promise<void> {
	requestQueue = requestQueue.then(
		() => sendRequestNow(request),
		() => sendRequestNow(request),
	);
	return requestQueue;
}

let reportSeq = Date.now() * 1000;

function reportVaultIdentity(): Promise<void> {
	const seq = ++reportSeq;
	return sendRequest({
		id: `${source}:${seq}`,
		method: "pane.report_metadata",
		params: {
			pane_id: paneId,
			source,
			tokens: { vault_broker: vaultBroker },
			seq,
		},
	});
}

export default function herdrVaultIdentity(pi: ExtensionAPI): void {
	if (!enabled) return;
	const publish = () => void reportVaultIdentity();
	pi.on("session_start", publish);
	pi.on("session_switch", publish);
}

import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { createServer, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { listingEventStream } from "../src/lib/listing-stream.js";

let child: ChildProcess;
let origin: string;
let indexerStatus = 200;
let pendingStats: ServerResponse | undefined;
let onStats: (() => void) | undefined;

const indexer = createServer((req, res) => {
    if (req.headers["x-ponder-secret"] !== "test-secret") {
        res.writeHead(404).end();
    } else if (req.url === "/ready") {
        res.writeHead(indexerStatus).end();
    } else if (req.url === "/stats" && onStats) {
        pendingStats = res;
        onStats();
    } else {
        res.writeHead(404, { "Content-Type": "application/json" }).end('{"error":"Token not found in burn records"}');
    }
});

beforeAll(async () => {
    indexer.listen(0, "127.0.0.1");
    await once(indexer, "listening");
    const { port } = indexer.address() as AddressInfo;
    child = spawn(process.execPath, ["--import", "tsx", "src/index.ts"], {
        env: {
            ...process.env,
            DOTENV_CONFIG_PATH: "/dev/null",
            HOST: "127.0.0.1",
            PORT: "0",
            PONDER_API_URL: "http://127.0.0.1:" + port,
            PONDER_API_SECRET: "test-secret",
            RPC_URL: "http://127.0.0.1:1",
            NORMIES_API_RELEASE: "candidate",
            RATE_LIMIT_MAX: "1",
            INTERNAL_SECRET: "",
            OPENSEA_API_KEY: "",
        },
        stdio: ["ignore", "pipe", "pipe"],
    });
    await new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error("API did not start")), 5_000);
        child.once("exit", (code) => {
            clearTimeout(timeout);
            reject(new Error("API exited with status " + code));
        });
        let output = "";
        child.stdout?.on("data", (chunk: Buffer) => {
            output += chunk.toString();
            const match = /Normies API listening on 127\.0\.0\.1 (\d+)/.exec(output);
            if (match) {
                clearTimeout(timeout);
                origin = "http://127.0.0.1:" + match[1];
                resolve();
            }
        });
    });
});

afterAll(async () => {
    if (child && child.exitCode === null && child.signalCode === null) {
        const exited = once(child, "exit");
        child.kill("SIGKILL");
        await exited;
    }
    indexer.closeAllConnections();
    await new Promise<void>((resolve) => indexer.close(() => resolve()));
});

describe("HTTP service lifecycle", () => {
    it("keeps liveness independent of readiness and exempts probes from the limit", async () => {
        const ready = await fetch(origin + "/ready");
        expect(ready.status).toBe(200);
        expect(await ready.json()).toEqual({ status: "ready", release: "candidate" });
        indexerStatus = 503;
        try {
            const failed = await fetch(origin + "/ready");
            expect(failed.status).toBe(503);
            expect(failed.headers.get("cache-control")).toBe("no-store");
            const health = await fetch(origin + "/health");
            expect(await health.json()).toEqual({ status: "ok" });
        } finally {
            indexerStatus = 200;
        }
    });

    it("prevents caching upstream errors and rate-limit responses", async () => {
        const headers = { "x-forwarded-for": "192.0.2.3" };
        const missing = await fetch(origin + "/history/burned/42", { headers });
        expect(missing.status).toBe(502);
        expect(missing.headers.get("cache-control")).toBe("no-store");
        const limited = await fetch(origin + "/history/burned/42", { headers });
        expect(limited.status).toBe(429);
        expect(limited.headers.get("cache-control")).toBe("no-store");
    });

    it("closes SSE on SIGTERM while an ordinary request finishes", async () => {
        const stream = await fetch(origin + "/rarity/listings/stream", {
            headers: { "x-forwarded-for": "192.0.2.4" },
        });
        expect(stream.status).toBe(200);
        const reader = stream.body!.getReader();
        expect(new TextDecoder().decode((await reader.read()).value)).toBe(":ok\n\n");

        const started = new Promise<void>((resolve) => { onStats = resolve; });
        const response = fetch(origin + "/history/stats", {
            headers: { "x-forwarded-for": "192.0.2.5" },
        });
        await started;
        const exited = once(child, "exit");
        child.kill("SIGTERM");
        expect((await reader.read()).done).toBe(true);
        pendingStats!.writeHead(200, { "Content-Type": "application/json" }).end("{}");
        expect((await response).status).toBe(200);
        expect(await exited).toEqual([0, null]);
    });
});

it("unsubscribes a disconnected SSE client", async () => {
    let subscriptions = 0;
    const controller = new AbortController();
    const reader = listingEventStream(controller.signal, () => {
        subscriptions++;
        return () => { subscriptions--; };
    }).getReader();
    await reader.read();
    expect(subscriptions).toBe(1);
    controller.abort();
    expect((await reader.read()).done).toBe(true);
    expect(subscriptions).toBe(0);
});

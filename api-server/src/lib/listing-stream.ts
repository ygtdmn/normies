type Subscribe = (listener: (event: unknown) => void) => () => void;

const activeStreams = new Set<() => void>();

export function closeListingStreams() {
    for (const close of activeStreams) close();
}

export function listingEventStream(signal: AbortSignal, subscribe: Subscribe) {
    let cleanup: () => void;
    return new ReadableStream<Uint8Array>({
        start(controller) {
            const encoder = new TextEncoder();
            let closed = false;
            const send = (message: string) => {
                if (closed) return;
                // Reconnect slow clients instead of holding an unbounded event queue.
                if ((controller.desiredSize ?? 0) <= 0) close();
                else controller.enqueue(encoder.encode(message));
            };
            const unsubscribe = subscribe((event) => send("data: " + JSON.stringify(event) + "\n\n"));
            const heartbeat = setInterval(() => send(": heartbeat\n\n"), 15_000).unref();
            cleanup = () => {
                if (closed) return;
                closed = true;
                clearInterval(heartbeat);
                unsubscribe();
                activeStreams.delete(close);
                signal.removeEventListener("abort", close);
            };
            function close() {
                if (closed) return;
                cleanup();
                controller.close();
            }
            activeStreams.add(close);
            signal.addEventListener("abort", close, { once: true });
            if (signal.aborted) close();
            else send(":ok\n\n");
        },
        cancel() {
            cleanup();
        },
    }, { highWaterMark: 64 });
}

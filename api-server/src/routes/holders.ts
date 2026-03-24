import { Hono } from "hono";
import { PONDER_ENABLED } from "../config.js";
import { getTokensByHolder } from "../services/ponder-data.js";

const holders = new Hono();

holders.get("/:address", async (c) => {
    if (!PONDER_ENABLED) {
        return c.json({ error: "Holder lookup requires PONDER_API_URL to be configured" }, 503);
    }
    const address = c.req.param("address");
    if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
        return c.json({ error: "Invalid Ethereum address" }, 400);
    }

    const tokenIds = await getTokensByHolder(address);
    return c.json({ address: address.toLowerCase(), tokenIds });
});

export { holders };

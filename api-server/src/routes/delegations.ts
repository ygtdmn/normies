import { Hono } from "hono";
import { getActiveDelegations } from "../services/ponder-data.js";

const delegations = new Hono();

delegations.get("/:address", async (c) => {
    const address = c.req.param("address");
    if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
        return c.json({ error: "Invalid Ethereum address" }, 400);
    }

    const rows = await getActiveDelegations(address);
    const owners: Record<string, string> = {};
    for (const row of rows) owners[row.tokenId] = row.owner.toLowerCase();

    return c.json({
        address: address.toLowerCase(),
        tokenIds: rows.map((row) => row.tokenId),
        owners,
    });
});

export { delegations };

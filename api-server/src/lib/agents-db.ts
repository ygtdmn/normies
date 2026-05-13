import { PrismaClient } from "../../node_modules/.prisma/agents-client/index.js";

const globalForPrisma = globalThis as unknown as { agentsPrisma: PrismaClient };

export const agentsPrisma = globalForPrisma.agentsPrisma || new PrismaClient();

if (process.env.NODE_ENV !== "production") globalForPrisma.agentsPrisma = agentsPrisma;

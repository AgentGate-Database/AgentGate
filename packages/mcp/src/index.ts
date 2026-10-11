import { randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";

import { McpServer } from "@modelcontextprotocol/server";
import { StdioServerTransport } from "@modelcontextprotocol/server/stdio";
import * as z from "zod/v4";

import { AgentGateApiError, AgentGateClient } from "../../sdk/src/index.ts";

export const agentgateToolNames = [
  "read_rows",
  "propose_change",
  "get_pr",
  "get_pr_diff",
  "list_prs",
  "get_pr_status",
] as const;

const jsonValue = z.union([z.string(), z.number(), z.boolean(), z.null()]);

export function statusExplanation(pr: {
  state?: string;
  execution_status?: { receipt?: unknown } | null;
}): string {
  if (pr.state === "pending_review") {
    return "Pending review. The business row has not been written.";
  }
  if (pr.state === "approved") {
    return "Approved. The business row has not been written.";
  }
  if (pr.state === "queued") {
    return "Queued. The business row is not committed yet.";
  }
  if (pr.state === "conflicted") {
    return "Conflicted. The proposal did not overwrite the current row.";
  }
  if (pr.state === "merged" && pr.execution_status && pr.execution_status.receipt) {
    return "Merged. A receipt records the committed write.";
  }
  if (pr.state === "merged") {
    return "Merged. The receipt is the record of the committed write.";
  }
  return "This state is not a committed write. The business row changes only after a merged receipt.";
}

export function formatToolError(error: unknown, token: string): string {
  const code = error instanceof AgentGateApiError ? `${error.code}: ` : "";
  const message = error instanceof Error ? error.message : "request failed";
  return redact(code + message, token);
}

function redact(text: string, token: string): string {
  if (!token) {
    return text;
  }
  return text.split(token).join("[redacted]");
}

function textResult(value: unknown, token: string) {
  return { content: [{ type: "text" as const, text: redact(JSON.stringify(value), token) }] };
}

function failure(error: unknown, token: string) {
  return { isError: true as const, content: [{ type: "text" as const, text: formatToolError(error, token) }] };
}

export function createAgentGateServer(client: AgentGateClient, token: string): McpServer {
  const server = new McpServer({ name: "agentgate", version: "0.1.0" });

  server.registerTool(
    "read_rows",
    {
      description:
        "Read explicit primary-key rows through AgentGate and return a tracked-read token. This does not create a proposal.",
      inputSchema: z.object({
        expires_in_seconds: z.number().int().positive().optional(),
        reads: z
          .array(
            z.object({
              schema: z.string(),
              table: z.string(),
              key: z.record(z.string(), z.string()),
              columns: z.array(z.string()).min(1),
            }),
          )
          .min(1),
      }),
    },
    async (args) => {
      try {
        const body = await client.createRead({
          expires_in_seconds: args.expires_in_seconds ?? 3600,
          reads: args.reads,
        });
        return textResult(body, token);
      } catch (error) {
        return failure(error, token);
      }
    },
  );

  server.registerTool(
    "propose_change",
    {
      description:
        "Propose an update. Pass the tracked-read token from read_rows. A successful call stores a proposal and does not write the business row.",
      inputSchema: z.object({
        title: z.string().min(1),
        reason: z.string().min(1),
        task_id: z.string().optional(),
        expires_in_seconds: z.number().int().positive(),
        read_tokens: z.array(z.string().min(1)).min(1),
        idempotency_key: z.string().min(1).optional(),
        changes: z
          .array(
            z.object({
              operation: z.literal("update"),
              schema: z.string(),
              table: z.string(),
              key: z.record(z.string(), z.string()),
              expected_revision: z.string().regex(/^[0-9]+$/),
              set: z.record(z.string(), jsonValue),
            }),
          )
          .min(1),
      }),
    },
    async (args) => {
      try {
        const body = await client.createProposal(
          {
            title: args.title,
            reason: args.reason,
            task_id: args.task_id,
            expires_in_seconds: args.expires_in_seconds,
            read_tokens: args.read_tokens,
            changes: args.changes,
          },
          args.idempotency_key ?? randomUUID(),
        );
        return textResult(
          {
            ...body,
            explanation: statusExplanation(body as { state?: string }),
          },
          token,
        );
      } catch (error) {
        return failure(error, token);
      }
    },
  );

  server.registerTool(
    "get_pr",
    {
      description: "Fetch proposal metadata, policy, and revision. This does not approve or merge.",
      inputSchema: z.object({ pr_id: z.string().min(1) }),
    },
    async ({ pr_id }) => {
      try {
        return textResult(await client.getPr(pr_id), token);
      } catch (error) {
        return failure(error, token);
      }
    },
  );

  server.registerTool(
    "get_pr_diff",
    {
      description: "Fetch the authorized before and after values for a proposal.",
      inputSchema: z.object({ pr_id: z.string().min(1) }),
    },
    async ({ pr_id }) => {
      try {
        return textResult(await client.getDiff(pr_id), token);
      } catch (error) {
        return failure(error, token);
      }
    },
  );

  server.registerTool(
    "list_prs",
    {
      description: "List proposals visible to this credential.",
      inputSchema: z.object({
        status: z.string().optional(),
        schema: z.string().optional(),
        table: z.string().optional(),
        limit: z.number().int().positive().optional(),
      }),
    },
    async (args) => {
      try {
        return textResult(
          await client.listPrs({
            status: args.status,
            schema: args.schema,
            table: args.table,
            limit: args.limit,
          }),
          token,
        );
      } catch (error) {
        return failure(error, token);
      }
    },
  );

  server.registerTool(
    "get_pr_status",
    {
      description:
        "Fetch the proposal state. Pending, queued, and conflicted results are not committed writes.",
      inputSchema: z.object({ pr_id: z.string().min(1) }),
    },
    async ({ pr_id }) => {
      try {
        const pr = await client.getPr(pr_id);
        const execution = pr.execution_status as { receipt?: unknown } | null | undefined;
        return textResult(
          {
            pr_id: pr.pr_id,
            state: pr.state,
            revision: pr.revision,
            content_hash: pr.content_hash,
            committed: pr.state === "merged" && Boolean(execution && execution.receipt),
            explanation: statusExplanation({
              state: typeof pr.state === "string" ? pr.state : undefined,
              execution_status: execution,
            }),
            execution_status: execution ?? null,
          },
          token,
        );
      } catch (error) {
        return failure(error, token);
      }
    },
  );

  return server;
}

async function main(): Promise<void> {
  const apiUrl = process.env.AGENTGATE_API_URL;
  const token = process.env.AGENTGATE_TOKEN;
  if (!apiUrl || !token) {
    console.error("AGENTGATE_API_URL and AGENTGATE_TOKEN are required");
    process.exit(1);
  }
  const client = new AgentGateClient({ baseUrl: apiUrl, token });
  const server = createAgentGateServer(client, token);
  await server.connect(new StdioServerTransport());
}

const invoked = process.argv[1] ? pathToFileURL(process.argv[1]).href : "";
if (import.meta.url === invoked) {
  main().catch((error: unknown) => {
    const message = error instanceof Error ? error.message : "mcp server failed";
    console.error(message);
    process.exit(1);
  });
}

import assert from "node:assert/strict";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

import { AgentGateApiError, AgentGateClient } from "../src/index.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const ready =
  process.env.AGENTGATE_API_BIN &&
  process.env.AGENTGATE_TEST_DATABASE_URL &&
  process.env.AGENTGATE_TEST_API_DATABASE_URL;

test("http and mcp proposals match and a proposer cannot approve", { skip: !ready }, async () => {
  const pg = (await import("pg")).default;
  const admin = new pg.Client({ connectionString: process.env.AGENTGATE_TEST_DATABASE_URL });
  await admin.connect();
  const port = 18084;
  const api = spawn(process.env.AGENTGATE_API_BIN, [], {
    env: {
      ...process.env,
      AGENTGATE_DATABASE_URL: process.env.AGENTGATE_TEST_API_DATABASE_URL,
      AGENTGATE_HTTP_HOST: "127.0.0.1",
      AGENTGATE_HTTP_PORT: String(port),
      AGENTGATE_CONTRACTS_DIR: join(root, "packages/contracts"),
    },
    stdio: "ignore",
  });
  const baseUrl = `http://127.0.0.1:${port}`;
  try {
    await waitForHealthy(baseUrl);
    if (api.exitCode !== null) {
      throw new Error(`API exited with ${api.exitCode} before the test called it`);
    }
    const proposer = await issue(admin, "sdk-proposer", "proposer");
    const reviewer = await issue(admin, "sdk-reviewer", "reviewer");
    await admin.query("SELECT agentgate.assign_reviewer($1::uuid, 'public', 'invoices')", [
      reviewer.principalId,
    ]);
    const invoiceId = await freshInvoice(admin);
    const revision = await revisionOf(admin, invoiceId);
    const change = {
      operation: "update",
      schema: "public",
      table: "invoices",
      key: { id: String(invoiceId) },
      expected_revision: revision,
      set: { payment_terms: "net_45" },
    };
    const http = new AgentGateClient({ baseUrl, token: proposer.token });
    const httpRead = await http.createRead({
      expires_in_seconds: 3600,
      reads: [{ schema: "public", table: "invoices", key: change.key, columns: ["payment_terms"] }],
    });
    const httpPr = await http.createProposal(
      {
        title: "HTTP proposal",
        reason: "Compare the HTTP client with MCP.",
        expires_in_seconds: 3600,
        read_tokens: [httpRead.token],
        changes: [change],
      },
      randomUUID(),
    );

    const mcp = new Client({ name: "agentgate-equivalence", version: "0.0.0" });
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: ["--experimental-strip-types", join(root, "packages/mcp/src/index.ts")],
      env: {
        ...process.env,
        AGENTGATE_API_URL: baseUrl,
        AGENTGATE_TOKEN: proposer.token,
      },
      stderr: "pipe",
    });
    await mcp.connect(transport);
    try {
      const read = await tool(mcp, "read_rows", {
        expires_in_seconds: 3600,
        reads: [{ schema: "public", table: "invoices", key: change.key, columns: ["payment_terms"] }],
      });
      const mcpPr = await tool(mcp, "propose_change", {
        title: "MCP proposal",
        reason: "Compare the HTTP client with MCP.",
        expires_in_seconds: 3600,
        read_tokens: [read.token],
        idempotency_key: randomUUID(),
        changes: [change],
      });
      assert.equal(mcpPr.policy_decision, httpPr.policy_decision);
      assert.equal(mcpPr.state, httpPr.state);
      const httpImage = await changeImage(admin, String(httpPr.pr_id));
      const mcpImage = await changeImage(admin, String(mcpPr.pr_id));
      assert.equal(httpImage.hash, httpPr.content_hash);
      assert.equal(mcpImage.hash, mcpPr.content_hash);
      assert.deepEqual(mcpImage.comparable, httpImage.comparable);
    } finally {
      await mcp.close();
    }

    await assert.rejects(
      () =>
        http.approve(
          String(httpPr.pr_id),
          { revision: httpPr.revision, content_hash: httpPr.content_hash },
          randomUUID(),
        ),
      (error: unknown) => {
        assert.ok(error instanceof AgentGateApiError);
        assert.equal(error.status, 403);
        assert.equal(error.code, "FORBIDDEN");
        return true;
      },
    );
  } finally {
    api.kill("SIGTERM");
    await admin.end();
  }
});

async function waitForHealthy(baseUrl: string): Promise<void> {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${baseUrl}/healthz`);
      if (response.ok) {
        return;
      }
    } catch {
      // The process is still binding its port.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("API did not become healthy");
}

async function issue(
  admin: { query: (sql: string, params?: unknown[]) => Promise<{ rows: Array<Record<string, string>> }> },
  name: string,
  kind: string,
): Promise<{ token: string; principalId: string }> {
  const secret = randomBytes(24).toString("base64url");
  const digest = createHash("sha256").update(secret).digest("hex");
  const scopes = {
    tables: [{ schema: "public", name: "invoices", tenants: ["acme"] }],
  };
  const result = await admin.query(
    "SELECT id::text AS credential_id, agentgate.issue_credential($1, $2, $3::jsonb, id, decode($4, 'hex'))::text AS principal_id " +
      "FROM (SELECT gen_random_uuid() AS id) generated",
    [name, kind, JSON.stringify(scopes), digest],
  );
  const row = result.rows[0];
  return {
    token: `agk_${row.credential_id}_${secret}`,
    principalId: row.principal_id,
  };
}

async function freshInvoice(admin: {
  query: (sql: string, params?: unknown[]) => Promise<{ rowCount: number | null }>;
}): Promise<number> {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const id = 3000000 + Math.floor(Math.random() * 1000000000);
    const inserted = await admin.query(
      "INSERT INTO public.invoices (id, tenant_id, payment_terms, notes) VALUES ($1, 'acme', 'net_15', 'sdk fixture') ON CONFLICT (id) DO NOTHING",
      [id],
    );
    if (inserted.rowCount === 1) {
      return id;
    }
  }
  throw new Error("could not insert a fresh invoice");
}

async function revisionOf(
  admin: { query: (sql: string, params?: unknown[]) => Promise<{ rows: Array<{ revision: string }> }> },
  id: number,
): Promise<string> {
  const result = await admin.query(
    "SELECT agentgate_revision::text AS revision FROM public.invoices WHERE id = $1",
    [id],
  );
  return result.rows[0].revision;
}

async function changeImage(
  admin: { query: (sql: string, params?: unknown[]) => Promise<{ rows: Array<Record<string, string>> }> },
  prId: string,
): Promise<{ hash: string; comparable: Record<string, unknown> }> {
  const result = await admin.query(
    "SELECT r.content_hash AS hash, r.canonical_content::text AS content " +
      "FROM agentgate.pr_revisions r JOIN agentgate.prs p ON p.active_revision_id = r.id WHERE p.id = $1::uuid",
    [prId],
  );
  const content = JSON.parse(result.rows[0].content) as Record<string, unknown>;
  delete content.expires_at;
  return { hash: result.rows[0].hash, comparable: content };
}

async function tool(client: Client, name: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
  const result = await client.callTool({ name, arguments: args });
  const block = result.content.find((item) => item.type === "text");
  const text = block && "text" in block ? block.text : "";
  const parsed = JSON.parse(text) as Record<string, unknown>;
  assert.notEqual(result.isError, true);
  return parsed;
}

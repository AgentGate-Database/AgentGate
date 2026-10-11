import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import pg from "pg";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

import { assertDemoEnvironment, demoHelpersEnabled, redactForDisplay } from "./demo-mode.js";

const root = dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT || 8090);
const apiUrl = (process.env.AGENTGATE_API_URL || "http://127.0.0.1:8080").replace(/\/$/, "");
const invoiceId = 482;
const sdkUrl = pathToFileURL(join(root, "../../packages/sdk/src/index.ts")).href;
const mcpEntry = join(root, "../../packages/mcp/src/index.ts");

function loadSecrets() {
  const file = process.env.DEMO_SECRETS;
  if (!file || !existsSync(file)) {
    return;
  }
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }
    const index = trimmed.indexOf("=");
    if (index > 0 && !process.env[trimmed.slice(0, index)]) {
      process.env[trimmed.slice(0, index)] = trimmed.slice(index + 1);
    }
  }
}

loadSecrets();
assertDemoEnvironment(process.env);

const proposerToken = process.env.AGENTGATE_PROPOSER_TOKEN || "";
const reviewerToken = process.env.AGENTGATE_REVIEWER_TOKEN || "";
if (!proposerToken || !reviewerToken) {
  console.error("demo proxy requires proposer and reviewer tokens");
  process.exit(1);
}

const { AgentGateClient, AgentGateApiError } = await import(sdkUrl);
const proposer = new AgentGateClient({ baseUrl: apiUrl, token: proposerToken });
const reviewer = new AgentGateClient({ baseUrl: apiUrl, token: reviewerToken });
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
let current = null;
let tracked = null;
let mcpClient = null;

function proposalChange() {
  return {
    title: "Correct invoice payment terms",
    reason: "Invoice terms differ from the signed purchase order.",
    task_id: "demo-invoice-482",
    expires_in_seconds: 3600,
    read_tokens: [tracked.token],
    changes: [
      {
        operation: "update",
        schema: "public",
        table: "invoices",
        key: { id: String(invoiceId) },
        expected_revision: tracked.revision,
        set: { payment_terms: tracked.proposed_terms },
      },
    ],
  };
}

async function readInvoice() {
  const result = await pool.query(
    "SELECT id::text, tenant_id, payment_terms, agentgate_revision::text AS revision " +
      "FROM public.invoices WHERE id = $1 AND tenant_id = 'acme'",
    [invoiceId],
  );
  if (result.rowCount !== 1) {
    throw new Error("sample invoice 482 is not in the acme tenant");
  }
  return result.rows[0];
}

async function mcp() {
  if (mcpClient) {
    return mcpClient;
  }
  const client = new Client({ name: "agentgate-demo", version: "0.1.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["--experimental-strip-types", mcpEntry],
    env: {
      PATH: process.env.PATH || "",
      HOME: process.env.HOME || "",
      TMPDIR: process.env.TMPDIR || "/tmp",
      AGENTGATE_API_URL: apiUrl,
      AGENTGATE_TOKEN: proposerToken,
    },
    stderr: "pipe",
  });
  await client.connect(transport);
  mcpClient = client;
  return client;
}

async function callTool(name, args) {
  const client = await mcp();
  const result = await client.callTool({ name, arguments: args });
  const block = Array.isArray(result.content) ? result.content.find((item) => item.type === "text") : null;
  const text = block && "text" in block ? block.text : "";
  let parsed = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = { error: { code: "INTERNAL", message: text || "MCP returned non-JSON" } };
  }
  if (result.isError) {
    const error = new Error(parsed?.error?.message || parsed?.message || text || "MCP tool failed");
    error.status = 422;
    error.body = parsed?.error ? parsed : { error: { code: "VALIDATION_FAILED", message: error.message } };
    throw error;
  }
  return { tool: name, arguments: args, result: parsed };
}

function rememberProposal(body) {
  current = {
    pr_id: body.pr_id,
    revision: body.revision,
    content_hash: body.content_hash,
    phase: body.state,
  };
}

function displayCall(call) {
  const shown = {
    tool: call.tool,
    request: call.arguments,
    response: call.result,
  };
  if (shown.request && shown.request.read_tokens) {
    shown.request = { ...shown.request, read_tokens: ["[redacted]"] };
  }
  return JSON.parse(redactForDisplay(shown));
}

async function prepare() {
  current = null;
  tracked = null;
  const call = await callTool("read_rows", {
    expires_in_seconds: 3600,
    reads: [
      {
        schema: "public",
        table: "invoices",
        key: { id: String(invoiceId) },
        columns: ["payment_terms"],
      },
    ],
  });
  const row = call.result.rows[0];
  const terms = row.values.payment_terms;
  tracked = {
    token: call.result.token,
    revision: row.revision,
    payment_terms: terms,
    proposed_terms: terms === "net_45" ? "net_60" : "net_45",
  };
  return {
    actor: "demo proposer",
    mcp: displayCall(call),
    invoice: {
      id: String(invoiceId),
      tenant_id: "acme",
      payment_terms: terms,
      revision: row.revision,
      proposed_terms: tracked.proposed_terms,
      tracked_read: true,
    },
  };
}

async function propose() {
  if (!tracked) {
    const error = new Error("prepare a tracked read first");
    error.status = 409;
    error.body = { error: { code: "VALIDATION_FAILED", message: error.message } };
    throw error;
  }
  const args = { ...proposalChange(), idempotency_key: randomUUID() };
  const call = await callTool("propose_change", args);
  rememberProposal(call.result);
  return {
    actor: "demo proposer",
    mcp: displayCall(call),
    pr_id: call.result.pr_id,
    state: call.result.state,
    revision: call.result.revision,
    source_pr_id: call.result.source_pr_id ?? null,
  };
}

function send(response, status, body) {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(body));
}

function fail(error) {
  return { status: error.status || 500, body: error.body || { error: { code: "INTERNAL", message: error.message } } };
}

async function handle(request, response) {
  const url = new URL(request.url || "/", `http://127.0.0.1:${port}`);
  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(readFileSync(join(root, "public", "index.html")));
    return;
  }
  if (request.method === "GET" && url.pathname === "/api/business") {
    send(response, 200, await readInvoice());
    return;
  }
  if (!demoHelpersEnabled(process.env) && (url.pathname === "/api/drift" || url.pathname === "/api/sample-agent")) {
    send(response, 404, { error: { code: "NOT_FOUND", message: "not found" } });
    return;
  }
  try {
    if (request.method === "POST" && url.pathname === "/api/prepare") {
      send(response, 200, await prepare());
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/propose") {
      send(response, 201, await propose());
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/sample-agent") {
      const prepared = await prepare();
      const sent = await propose();
      send(response, 201, { actor: "demo proposer", prepared, sent });
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/drift") {
      if (!current || current.phase !== "approved") {
        send(response, 409, {
          error: { code: "VALIDATION_FAILED", message: "drift the fixture only after approval and before merge" },
        });
        return;
      }
      const row = await readInvoice();
      const other = row.payment_terms === "net_30" ? "net_15" : "net_30";
      await pool.query(
        "UPDATE public.invoices SET payment_terms = $2 WHERE id = $1 AND tenant_id = 'acme'",
        [invoiceId, other],
      );
      send(response, 200, {
        actor: "another application",
        invoice_id: String(invoiceId),
        payment_terms: other,
        note: "An ordinary writer changed the fixture. AgentGate has not merged.",
      });
      return;
    }
    if (!current) {
      send(response, 409, { error: { code: "VALIDATION_FAILED", message: "send a proposal first" } });
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/show") {
      const pr = await proposer.getPr(current.pr_id);
      const diff = await proposer.getDiff(current.pr_id);
      send(response, 200, {
        actor: "demo reviewer",
        note: "Fetched for review. This proposal was already stored.",
        title: pr.title,
        reason: pr.reason,
        revision: pr.revision,
        content_hash: pr.content_hash,
        state: pr.state,
        diff,
      });
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/status") {
      send(response, 200, await proposer.getPr(current.pr_id));
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/approve") {
      const body = await reviewer.approve(
        current.pr_id,
        { revision: current.revision, content_hash: current.content_hash },
        randomUUID(),
      );
      current.phase = "approved";
      send(response, 200, { actor: "demo reviewer", ...body, wrote_business_row: false });
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/merge") {
      const body = await proposer.merge(
        current.pr_id,
        { revision: current.revision, content_hash: current.content_hash },
        randomUUID(),
      );
      current.phase = body.state;
      send(response, body.state === "queued" ? 202 : 200, body);
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/revert") {
      const body = await proposer.revert(
        current.pr_id,
        {
          title: "Revert invoice payment terms",
          reason: "Restore the payment terms captured by the merge receipt.",
          expires_in_seconds: 3600,
        },
        randomUUID(),
      );
      rememberProposal(body);
      send(response, 201, body);
      return;
    }
  } catch (error) {
    if (error instanceof AgentGateApiError) {
      send(response, error.status, { error: { code: error.code, message: error.message } });
      return;
    }
    const failed = fail(error);
    send(response, failed.status, failed.body);
    return;
  }
  send(response, 404, { error: { code: "NOT_FOUND", message: "not found" } });
}

createServer((request, response) => {
  handle(request, response).catch((error) => {
    send(response, 500, { error: { code: "INTERNAL", message: error.message } });
  });
}).listen(port, "0.0.0.0", () => {
  console.error(`demo proxy listening on ${port}`);
});

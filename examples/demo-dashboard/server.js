import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const root = dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT || 8090);
const apiUrl = (process.env.AGENTGATE_API_URL || "http://127.0.0.1:8080").replace(/\/$/, "");
const invoiceId = 482;

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

const proposerToken = process.env.AGENTGATE_PROPOSER_TOKEN || "";
const reviewerToken = process.env.AGENTGATE_REVIEWER_TOKEN || "";
if (!proposerToken || !reviewerToken || !process.env.DATABASE_URL) {
  console.error("demo proxy requires DATABASE_URL and proposer and reviewer tokens");
  process.exit(1);
}

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
let current = null;
let tracked = null;

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

async function api(method, path, token, body) {
  const headers = { authorization: `Bearer ${token}` };
  if (body !== undefined) {
    headers["content-type"] = "application/json";
    headers["idempotency-key"] = randomUUID();
  }
  const response = await fetch(`${apiUrl}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let parsed = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = { error: { code: "INTERNAL", message: "API returned non-JSON" } };
  }
  return { status: response.status, body: parsed };
}

function send(response, status, body) {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(body));
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
  if (request.method === "POST" && url.pathname === "/api/prepare") {
    current = null;
    tracked = null;
    const read = await api("POST", "/v1/reads", proposerToken, {
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
    if (read.status !== 200 || !read.body || !read.body.token || !Array.isArray(read.body.rows)) {
      send(response, read.status, read.body);
      return;
    }
    const row = read.body.rows[0];
    const terms = row.values.payment_terms;
    tracked = {
      token: read.body.token,
      revision: row.revision,
      payment_terms: terms,
      proposed_terms: terms === "net_45" ? "net_60" : "net_45",
    };
    send(response, 200, {
      id: String(invoiceId),
      tenant_id: "acme",
      payment_terms: terms,
      revision: row.revision,
      proposed_terms: tracked.proposed_terms,
      tracked_read: true,
    });
    return;
  }
  if (request.method === "POST" && url.pathname === "/api/propose") {
    if (!tracked) {
      send(response, 409, {
        error: { code: "VALIDATION_FAILED", message: "prepare a tracked read first" },
      });
      return;
    }
    const result = await api("POST", "/v1/prs", proposerToken, {
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
    });
    if (result.status === 201 && result.body) {
      current = {
        pr_id: result.body.pr_id,
        revision: result.body.revision,
        content_hash: result.body.content_hash,
      };
    }
    send(response, result.status, result.body);
    return;
  }
  if (!current) {
    send(response, 409, { error: { code: "VALIDATION_FAILED", message: "send a proposal first" } });
    return;
  }
  if (request.method === "POST" && url.pathname === "/api/show") {
    const result = await api("GET", `/v1/prs/${current.pr_id}`, proposerToken);
    send(response, result.status, result.body);
    return;
  }
  if (request.method === "GET" && url.pathname === "/api/status") {
    const result = await api("GET", `/v1/prs/${current.pr_id}`, proposerToken);
    send(response, result.status, result.body);
    return;
  }
  if (request.method === "POST" && url.pathname === "/api/approve") {
    const result = await api("POST", `/v1/prs/${current.pr_id}/approve`, reviewerToken, {
      revision: current.revision,
      content_hash: current.content_hash,
    });
    send(response, result.status, result.body);
    return;
  }
  if (request.method === "POST" && url.pathname === "/api/merge") {
    const result = await api("POST", `/v1/prs/${current.pr_id}/merge`, proposerToken, {
      revision: current.revision,
      content_hash: current.content_hash,
    });
    send(response, result.status, result.body);
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

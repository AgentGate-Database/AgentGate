import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

import { agentgateToolNames, formatToolError, statusExplanation } from "../src/index.ts";

const entry = join(dirname(fileURLToPath(import.meta.url)), "../src/index.ts");

test("status text does not describe a queue or conflict as a commit", () => {
  assert.match(statusExplanation({ state: "queued" }), /not committed/i);
  assert.match(statusExplanation({ state: "conflicted" }), /did not overwrite/i);
  assert.match(statusExplanation({ state: "pending_review" }), /has not been written/i);
  assert.match(
    statusExplanation({ state: "merged", execution_status: { receipt: { receipt_id: "r" } } }),
    /receipt/i,
  );
});

test("tool errors redact the bearer token", () => {
  const token = "agk_secret-token";
  const text = formatToolError(new Error(`authorization failed for ${token}`), token);
  assert.equal(text.includes(token), false);
  assert.match(text, /\[redacted\]/);
});

test("the server exposes only the agent tools", async () => {
  const client = new Client({ name: "agentgate-test", version: "0.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["--experimental-strip-types", entry],
    env: {
      ...process.env,
      AGENTGATE_API_URL: "http://127.0.0.1:9",
      AGENTGATE_TOKEN: "agk_test-token",
    },
    stderr: "pipe",
  });
  await client.connect(transport);
  try {
    const listed = await client.listTools();
    const names = listed.tools.map((tool) => tool.name).sort();
    assert.deepEqual(names, [...agentgateToolNames].sort());
    for (const forbidden of ["approve", "reject", "merge", "publish_policy", "register_webhook"]) {
      assert.equal(names.includes(forbidden), false);
    }
  } finally {
    await client.close();
  }
});

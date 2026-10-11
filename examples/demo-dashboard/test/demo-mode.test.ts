import assert from "node:assert/strict";
import test from "node:test";

import { assertDemoEnvironment, demoHelpersEnabled, redactForDisplay } from "../demo-mode.js";

test("demo mode refuses a remote database", () => {
  assert.throws(
    () =>
      assertDemoEnvironment({
        AGENTGATE_DEMO: "1",
        DATABASE_URL: "postgresql://postgres:postgres@db.example.com:5432/agentgate",
      }),
    /remote database/,
  );
});

test("demo helpers are absent when demo mode is off", () => {
  assert.equal(demoHelpersEnabled({ AGENTGATE_DEMO: "1" }), true);
  assert.equal(demoHelpersEnabled({}), false);
  assert.equal(demoHelpersEnabled({ AGENTGATE_DEMO: "0" }), false);
});

test("display redaction hides bearer tokens, read tokens, and webhook secrets", () => {
  const shown = redactForDisplay({
    authorization: "agk_11111111-1111-4111-8111-111111111111_secret",
    token: "agr_22222222-2222-4222-8222-222222222222_abcdef",
    secret: "whsec_0123456789abcdef",
  });
  assert.equal(shown.includes("agk_"), false);
  assert.equal(shown.includes("agr_"), false);
  assert.equal(shown.includes("whsec_"), false);
});

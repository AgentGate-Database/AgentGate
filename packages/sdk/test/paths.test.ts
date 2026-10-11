import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { sdkOperations } from "../src/index.ts";

function declaredOperations(openapi: string): Set<string> {
  const found = new Set<string>();
  let current = "";
  for (const line of openapi.split("\n")) {
    const path = line.match(/^  (\/v1\/[^:]+):/);
    if (path) {
      current = path[1];
      continue;
    }
    const method = line.match(/^    (get|post):/);
    if (method && current) {
      found.add(`${method[1].toUpperCase()} ${current}`);
    }
  }
  return found;
}

test("sdk operations are declared in OpenAPI", () => {
  const openapi = readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "../../contracts/openapi.yaml"),
    "utf8",
  );
  const declared = declaredOperations(openapi);
  for (const operation of sdkOperations) {
    assert.equal(declared.has(operation), true, operation);
  }
});

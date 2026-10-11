export function assertDemoEnvironment(env) {
  if (env.AGENTGATE_DEMO !== "1") {
    throw new Error("AGENTGATE_DEMO=1 is required");
  }
  if (!env.DATABASE_URL) {
    throw new Error("DATABASE_URL is required");
  }
  let host = "";
  try {
    host = new URL(env.DATABASE_URL).hostname;
  } catch {
    throw new Error("DATABASE_URL is invalid");
  }
  if (host !== "localhost" && host !== "127.0.0.1" && host !== "db") {
    throw new Error("demo mode refuses a remote database");
  }
}

export function demoHelpersEnabled(env) {
  return env.AGENTGATE_DEMO === "1";
}

export function redactForDisplay(value) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return text
    .replace(/agk_[A-Za-z0-9_-]+/g, "[redacted]")
    .replace(/agr_[A-Za-z0-9_-]+/g, "[redacted]")
    .replace(/whsec_[0-9a-f]+/g, "[redacted]");
}

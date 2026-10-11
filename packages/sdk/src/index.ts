export const sdkOperations = [
  "POST /v1/reads",
  "POST /v1/prs",
  "GET /v1/prs",
  "GET /v1/prs/{id}",
  "GET /v1/prs/{id}/diff",
  "GET /v1/prs/{id}/events",
  "POST /v1/prs/{id}/approve",
  "POST /v1/prs/{id}/reject",
  "POST /v1/prs/{id}/revert",
  "POST /v1/prs/{id}/merge",
] as const;

export class AgentGateApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details: unknown;

  constructor(status: number, body: unknown) {
    const error = errorBody(body);
    super(error.message);
    this.name = "AgentGateApiError";
    this.status = status;
    this.code = error.code;
    this.details = error.details;
  }
}

export interface AgentGateClientOptions {
  baseUrl: string;
  token: string;
  fetch?: typeof fetch;
}

type Json = Record<string, unknown>;

export class AgentGateClient {
  private readonly baseUrl: string;
  private readonly token: string;
  private readonly fetchImpl: typeof fetch;

  constructor(options: AgentGateClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/$/, "");
    this.token = options.token;
    this.fetchImpl = options.fetch ?? fetch;
  }

  createRead(body: Json, idempotencyKey?: string): Promise<Json> {
    return this.request("POST", "/v1/reads", body, idempotencyKey);
  }

  createProposal(body: Json, idempotencyKey: string): Promise<Json> {
    return this.request("POST", "/v1/prs", body, idempotencyKey);
  }

  listPrs(query: Record<string, string | number | undefined> = {}): Promise<Json> {
    return this.request("GET", `/v1/prs${queryString(query)}`);
  }

  getPr(prId: string): Promise<Json> {
    return this.request("GET", `/v1/prs/${encodeURIComponent(prId)}`);
  }

  getDiff(prId: string): Promise<Json> {
    return this.request("GET", `/v1/prs/${encodeURIComponent(prId)}/diff`);
  }

  listEvents(prId: string): Promise<Json> {
    return this.request("GET", `/v1/prs/${encodeURIComponent(prId)}/events`);
  }

  approve(prId: string, body: Json, idempotencyKey: string): Promise<Json> {
    return this.request("POST", `/v1/prs/${encodeURIComponent(prId)}/approve`, body, idempotencyKey);
  }

  reject(prId: string, body: Json, idempotencyKey: string): Promise<Json> {
    return this.request("POST", `/v1/prs/${encodeURIComponent(prId)}/reject`, body, idempotencyKey);
  }

  revert(prId: string, body: Json, idempotencyKey: string): Promise<Json> {
    return this.request("POST", `/v1/prs/${encodeURIComponent(prId)}/revert`, body, idempotencyKey);
  }

  merge(prId: string, body: Json, idempotencyKey: string): Promise<Json> {
    return this.request("POST", `/v1/prs/${encodeURIComponent(prId)}/merge`, body, idempotencyKey);
  }

  private async request(
    method: string,
    path: string,
    body?: Json,
    idempotencyKey?: string,
  ): Promise<Json> {
    const headers: Record<string, string> = { authorization: `Bearer ${this.token}` };
    if (body !== undefined) {
      headers["content-type"] = "application/json";
    }
    if (idempotencyKey) {
      headers["idempotency-key"] = idempotencyKey;
    }
    const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    let parsed: unknown = null;
    if (text) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = { error: { code: "INTERNAL", message: "API returned non-JSON" } };
      }
    }
    if (!response.ok) {
      throw new AgentGateApiError(response.status, parsed);
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new AgentGateApiError(response.status, {
        error: { code: "INTERNAL", message: "API returned an empty body" },
      });
    }
    return parsed as Json;
  }
}

function queryString(query: Record<string, string | number | undefined>): string {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== "") {
      params.set(key, String(value));
    }
  }
  const text = params.toString();
  return text ? `?${text}` : "";
}

function errorBody(body: unknown): { code: string; message: string; details: unknown } {
  if (body && typeof body === "object" && "error" in body) {
    const error = (body as { error?: { code?: unknown; message?: unknown; details?: unknown } }).error;
    return {
      code: typeof error?.code === "string" ? error.code : "INTERNAL",
      message: typeof error?.message === "string" ? error.message : "request failed",
      details: error?.details,
    };
  }
  return { code: "INTERNAL", message: "request failed", details: undefined };
}

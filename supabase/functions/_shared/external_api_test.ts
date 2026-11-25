import { EventEmitter } from "node:events";
import {
  authHeaders,
  executeExternalRequest,
  executeExternalResource,
  ExternalApiError,
  isPublicIpv4,
  mergeCredentials,
  resourceUrl,
  safeBaseUrl,
  sendExternalApiRequest,
} from "./external_api.ts";

function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
async function rejects(fn: () => unknown | Promise<unknown>) {
  try {
    await fn();
  } catch {
    return;
  }
  throw new Error("expected rejection");
}

Deno.test("URLs and paths reject SSRF and origin changes", async () => {
  for (
    const url of [
      "http://example.com",
      "https://127.0.0.1",
      "https://user:pass@example.com",
      "https://localhost",
      "https://example.com:8443",
      "https://example.com?q=x",
    ]
  ) {
    await rejects(() => safeBaseUrl(url));
  }
  for (
    const path of [
      "//evil.com",
      "/\\evil",
      "/%2e%2e/secret",
      "/x?token=bad",
      "/%252e%252e/x",
    ]
  ) {
    await rejects(() => resourceUrl("https://example.com/api", path, {}));
  }
  assert(
    resourceUrl("https://example.com/api", "/users", { q: "a b" }).href ===
      "https://example.com/api/users?q=a+b",
  );
  await rejects(() => resourceUrl("https://example.com", "/x", { x: {} }));
  for (
    const ip of [
      "10.0.0.1",
      "169.254.169.254",
      "127.0.0.1",
      "100.64.1.1",
      "192.168.1.1",
      "224.1.1.1",
    ]
  ) assert(!isPublicIpv4(ip));
  assert(isPublicIpv4("8.8.8.8"));
});

Deno.test("credentials validated and redacted, result retains upstream status", async () => {
  await rejects(() =>
    authHeaders("api_key", { header_name: "Host", header_value: "secret" })
  );
  const integration = {
    base_url: "https://example.com",
    auth_type: "bearer_token",
    auth_config: { token: "secret" },
    enabled: true,
  };
  const result = await executeExternalRequest(
    integration,
    { path: "/x", http_method: "POST" },
    {},
    { a: 1 },
    "run:1",
    async (_url, method, headers, body) => {
      assert(
        method === "POST" && headers.authorization === "Bearer secret" &&
          body === '{"a":1}',
      );
      assert(headers["idempotency-key"] === "run:1");
      return { status: 422, text: '{"message":"secret","ok":false}' };
    },
  );
  assert(
    !result.ok && result.status_code === 422 &&
      JSON.stringify(result.body).includes("[REDACTED]"),
  );
  const filtered = await executeExternalRequest(
    integration,
    { path: "/x", http_method: "GET" },
    { status: "active", limit: 5 },
    { ignored: true },
    undefined,
    async (url, method, headers, body) => {
      assert(method === "GET" && body === undefined);
      assert(headers["content-type"] === undefined);
      assert(url.searchParams.get("status") === "active");
      assert(url.searchParams.get("limit") === "5");
      return { status: 200, text: '{"items":[]}' };
    },
  );
  assert(filtered.ok && filtered.status_code === 200);
});

Deno.test("editing preserves blank credentials only for the same authentication type", async () => {
  const existing = {
    auth_type: "api_key",
    auth_config: { header_name: "X-Key", header_value: "secret" },
  };
  const saved = mergeCredentials("api_key", {
    header_name: "",
    header_value: "",
  }, existing);
  assert(saved.header_name === "X-Key" && saved.header_value === "secret");
  assert(Object.keys(mergeCredentials("none", {}, existing)).length === 0);
  await rejects(() =>
    mergeCredentials("bearer_token", { token: "" }, existing)
  );
  await rejects(() =>
    mergeCredentials("api_key", { token: "secret" }, existing)
  );
  await rejects(() =>
    executeExternalRequest(
      {
        base_url: "https://example.com",
        auth_type: "none",
        auth_config: {},
        enabled: true,
      },
      { path: "/x", http_method: "POST" },
      {},
      { n: NaN },
    )
  );
});

Deno.test("all write methods return HTTP rejection but propagate ambiguous failures without retry", async () => {
  const integration = {
    base_url: "https://example.com",
    auth_type: "none",
    auth_config: {},
    enabled: true,
  };
  for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
    const resource = { path: "/orders", http_method: method };
    for (const status of [400, 422, 500, 503]) {
      const result = await executeExternalRequest(
        integration,
        resource,
        {},
        { id: 1 },
        undefined,
        async () => ({ status, text: '{"error":"rejected"}' }),
      );
      assert(result.ok === false && result.status_code === status);
      assert(JSON.stringify(result.body) === '{"error":"rejected"}');
    }
    for (const status of [502, 504]) {
      let attempts = 0;
      const expected = new ExternalApiError(
        "Fallo externo sanitizado",
        status,
        "unknown",
      );
      try {
        await executeExternalRequest(
          integration,
          resource,
          {},
          { id: 1 },
          undefined,
          async () => {
            attempts++;
            throw expected;
          },
        );
        throw new Error("expected exception");
      } catch (error) {
        assert(
          error instanceof ExternalApiError && error === expected &&
            error.outcome === "unknown",
        );
      }
      assert(attempts === 1, "mutations must never be retried");
    }
  }
});

Deno.test("outbound transport pins checked DNS, blocks redirects and limits response", async () => {
  let requests = 0;
  let status = 200;
  let bytes = 2;
  const dependencies = {
    resolve: async () => [{ address: "8.8.8.8", family: 4 }],
    timeoutMs: 100,
    request: (
      _url: URL,
      options: { lookup: Function; agent: unknown },
      callback: Function,
    ) => {
      requests++;
      assert(
        options.agent === false,
        "connections must not reuse unpinned sockets",
      );
      options.lookup(
        "example.com",
        {},
        (_err: unknown, address: string) => assert(address === "8.8.8.8"),
      );
      const req = new EventEmitter() as EventEmitter & {
        end: () => void;
        destroy: () => void;
      };
      req.destroy = () => {};
      req.end = () =>
        queueMicrotask(() => {
          const response = new EventEmitter() as EventEmitter & {
            statusCode: number;
            destroy: () => void;
          };
          response.statusCode = status;
          response.destroy = () => {};
          callback(response);
          if (status === 200) {
            response.emit("data", new Uint8Array(bytes));
            response.emit("end");
          }
        });
      return req;
    },
  } as unknown as NonNullable<Parameters<typeof sendExternalApiRequest>[4]>;
  const url = new URL("https://example.com");
  assert(
    (await sendExternalApiRequest(url, "GET", {}, undefined, dependencies))
      .status === 200,
  );
  status = 302;
  await rejects(() =>
    sendExternalApiRequest(url, "GET", {}, undefined, dependencies)
  );
  assert(requests === 2, "redirect must not trigger another request");
  status = 200;
  bytes = 256 * 1024 + 1;
  await rejects(() =>
    sendExternalApiRequest(url, "GET", {}, undefined, dependencies)
  );
  dependencies.resolve = (async () => [{
    address: "127.0.0.1",
    family: 4,
  }]) as unknown as typeof dependencies.resolve;
  await rejects(() =>
    sendExternalApiRequest(url, "GET", {}, undefined, dependencies)
  );
  assert(
    Number(requests) === 3,
    "private DNS must be rejected before connecting",
  );
  dependencies.timeoutMs = 1;
  dependencies.resolve = (async () => {
    await new Promise((resolve) => setTimeout(resolve, 10));
    return [{ address: "8.8.8.8", family: 4 }];
  }) as unknown as typeof dependencies.resolve;
  await rejects(() =>
    sendExternalApiRequest(url, "GET", {}, undefined, dependencies)
  );
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert(
    Number(requests) === 3,
    "timed out DNS must never send a late request",
  );
});

Deno.test("automation requires resource enablement and explicit write opt-in, scoped by tenant", async () => {
  const calls: string[] = [];
  let resource: Record<string, unknown> | null = {
    integration_id: "integration",
    enabled: true,
    http_method: "POST",
    path: "/x",
    enabled_for_automation: false,
    allow_automation_writes: false,
  };
  const db = {
    from(table: string) {
      calls.push(table);
      const builder = {
        select: (_: string) => builder,
        eq: (key: string, value: string) => {
          calls.push(`${key}:${value}`);
          return builder;
        },
        maybeSingle: () =>
          Promise.resolve({
            data: table === "tenant_api_resources" ? resource : null,
            error: null,
          }),
      };
      return builder;
    },
  };
  const input = {
    tenantId: "tenant-a",
    resourceId: "resource",
    automation: true,
  };
  await rejects(() => executeExternalResource(db, input));
  assert(
    !calls.includes("tenant_api_integrations") &&
      calls.includes("tenant_id:tenant-a"),
  );
  resource.enabled_for_automation = true;
  await rejects(() => executeExternalResource(db, input));
  assert(!calls.includes("tenant_api_integrations"));
  resource.allow_automation_writes = true;
  await rejects(() => executeExternalResource(db, input));
  assert(calls.includes("tenant_api_integrations"));
  calls.length = 0;
  resource.http_method = "GET";
  resource.allow_automation_writes = false;
  await rejects(() => executeExternalResource(db, input));
  assert(
    calls.includes("tenant_api_integrations"),
    "GET does not require the write opt-in",
  );
  resource = null;
  await rejects(() =>
    executeExternalResource(db, { ...input, tenantId: "tenant-b" })
  );
});

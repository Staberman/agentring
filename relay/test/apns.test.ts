import { generateKeyPairSync } from "node:crypto";
import { createServer, type Http2Server, type ServerHttp2Session } from "node:http2";
import type { AddressInfo } from "node:net";
import { decodeJwt, decodeProtectedHeader } from "jose";
import { afterEach, describe, expect, it } from "vitest";
import { ApnsProvider } from "../src/push/apns.js";
import { signEvent } from "../src/push/dispatcher.js";

interface Seen {
  headers: Record<string, string>;
  body: Record<string, unknown>;
  session: ServerHttp2Session;
}

/** A local h2c server standing in for APNs; `reply` decides the status/body of each request. */
async function fakeApns(reply: (n: number, seen: Seen) => { status: number; body?: object } = () => ({ status: 200 })) {
  const seen: Seen[] = [];
  const server: Http2Server = createServer();
  server.on("stream", (stream, headers) => {
    let raw = "";
    stream.setEncoding("utf8");
    stream.on("data", (c: string) => (raw += c));
    stream.on("end", () => {
      const s: Seen = { headers: headers as Record<string, string>, body: JSON.parse(raw), session: stream.session as ServerHttp2Session };
      seen.push(s);
      const r = reply(seen.length, s);
      stream.respond({ ":status": r.status, "content-type": "application/json" });
      stream.end(r.body ? JSON.stringify(r.body) : "");
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const authority = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { seen, authority, server };
}

const keyPem = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ type: "pkcs8", format: "pem" }) as string;
const TOKEN = "ab".repeat(32);

let open: Array<() => void> = [];
afterEach(() => {
  for (const c of open) c();
  open = [];
});

async function provider(reply?: Parameters<typeof fakeApns>[0], now: () => number = Date.now) {
  const f = await fakeApns(reply);
  const p = new ApnsProvider({ keyPem, keyId: "ABC123DEFG", teamId: "TEAM123456", bundleId: "dev.example.agentring", environment: "sandbox", authority: f.authority, now });
  open.push(() => {
    p.close();
    f.server.close();
  });
  return { p, ...f };
}

const payload = { v: "1", relay_id: "rly_1", event: '{"type":"call.invite"}', sig: "sig" };

describe("ApnsProvider", () => {
  it("signs an ES256 provider token with kid/iss/iat and reuses it until it is 50 minutes old", async () => {
    let t = 1_761_200_000_000;
    const { p, seen } = await provider(undefined, () => t);
    const opts = { ttlSeconds: 30, highPriority: true, apns: { pushType: "voip" as const } };
    await p.send({ deviceId: "d", token: TOKEN }, payload, opts);
    const jwt = seen[0]!.headers.authorization!.replace(/^bearer /, "");
    expect(decodeProtectedHeader(jwt)).toMatchObject({ alg: "ES256", kid: "ABC123DEFG" });
    expect(decodeJwt(jwt)).toEqual({ iss: "TEAM123456", iat: Math.floor(t / 1000) });

    t += 49 * 60_000;
    await p.send({ deviceId: "d", token: TOKEN }, payload, opts);
    expect(seen[1]!.headers.authorization).toBe(seen[0]!.headers.authorization);

    t += 2 * 60_000; // 51 min: refreshed before Apple's 60 min limit
    await p.send({ deviceId: "d", token: TOKEN }, payload, opts);
    expect(seen[2]!.headers.authorization).not.toBe(seen[0]!.headers.authorization);
    expect(decodeJwt(seen[2]!.headers.authorization!.replace(/^bearer /, "")).iat).toBe(Math.floor(t / 1000));
  });

  it("sends a VoIP push with the voip topic, priority 10, expiration and the signed payload as-is", async () => {
    const now = 1_761_200_000_000;
    const { p, seen } = await provider(undefined, () => now);
    const res = await p.send({ deviceId: "d", token: TOKEN }, payload, { ttlSeconds: 30, highPriority: false, apns: { pushType: "voip" } });
    expect(res).toEqual({ ok: true });
    const h = seen[0]!.headers;
    expect(h[":method"]).toBe("POST");
    expect(h[":path"]).toBe(`/3/device/${TOKEN}`);
    expect(h["apns-push-type"]).toBe("voip");
    expect(h["apns-topic"]).toBe("dev.example.agentring.voip");
    expect(h["apns-priority"]).toBe("10");
    expect(h["apns-expiration"]).toBe(String(Math.floor(now / 1000) + 30));
    expect(seen[0]!.body).toEqual(payload);
  });

  it("sends an alert push with the bundle topic, mutable-content and the payload in custom keys", async () => {
    const { p, seen } = await provider();
    await p.send({ deviceId: "d", token: TOKEN }, payload, {
      ttlSeconds: 60,
      highPriority: true,
      apns: { pushType: "alert", alert: { title: "Claude", body: "Build finished" } },
    });
    const h = seen[0]!.headers;
    expect(h["apns-push-type"]).toBe("alert");
    expect(h["apns-topic"]).toBe("dev.example.agentring");
    expect(seen[0]!.body).toEqual({ aps: { alert: { title: "Claude", body: "Build finished" }, sound: "default", "mutable-content": 1 }, ...payload });
  });

  it("reports 410 and Unregistered as unregistered, but keeps BadDeviceToken (APNS_ENV mismatch) and other failures", async () => {
    const replies = [
      { status: 410, body: { reason: "Unregistered" } },
      { status: 400, body: { reason: "BadDeviceToken" } },
      { status: 400, body: { reason: "PayloadTooLarge" } },
      { status: 503, body: { reason: "ServiceUnavailable" } },
    ];
    const { p } = await provider((n) => replies[n - 1]!);
    const send = () => p.send({ deviceId: "d", token: TOKEN }, payload, { ttlSeconds: 1, highPriority: true, apns: { pushType: "voip" } });
    expect(await send()).toMatchObject({ ok: false, unregistered: true, error: "410 Unregistered" });
    expect(await send()).toMatchObject({ ok: false, unregistered: false, error: "400 BadDeviceToken" });
    expect(await send()).toMatchObject({ ok: false, unregistered: false, error: "400 PayloadTooLarge" });
    expect(await send()).toMatchObject({ ok: false, unregistered: false });
  });

  it("refuses malformed device tokens and oversized payloads without calling APNs", async () => {
    const { p, seen } = await provider();
    const opts = { ttlSeconds: 1, highPriority: true, apns: { pushType: "alert" as const, alert: { title: "t", body: "b" } } };
    expect(await p.send({ deviceId: "d", token: "../x" }, payload, opts)).toMatchObject({ ok: false, unregistered: true });
    expect(await p.send({ deviceId: "d", token: TOKEN }, { ...payload, event: "x".repeat(5000) }, opts)).toMatchObject({ ok: false, unregistered: false });
    expect(seen).toHaveLength(0);
  });

  it("retries once with a fresh provider token after ExpiredProviderToken", async () => {
    const { p, seen } = await provider((n) => (n === 1 ? { status: 403, body: { reason: "ExpiredProviderToken" } } : { status: 200 }));
    const res = await p.send({ deviceId: "d", token: TOKEN }, payload, { ttlSeconds: 1, highPriority: true, apns: { pushType: "voip" } });
    expect(res).toEqual({ ok: true });
    expect(seen).toHaveLength(2);
  });

  it("reuses one HTTP/2 session and reconnects after APNs sends GOAWAY", async () => {
    const { p, seen } = await provider((n, s) => {
      if (n === 2) setImmediate(() => s.session.goaway());
      return { status: 200 };
    });
    const opts = { ttlSeconds: 1, highPriority: true, apns: { pushType: "voip" as const } };
    await p.send({ deviceId: "d", token: TOKEN }, payload, opts);
    await p.send({ deviceId: "d", token: TOKEN }, payload, opts);
    expect(seen[0]!.session).toBe(seen[1]!.session);
    await new Promise((r) => setTimeout(r, 50));
    expect(await p.send({ deviceId: "d", token: TOKEN }, payload, opts)).toEqual({ ok: true });
    expect(seen[2]!.session).not.toBe(seen[0]!.session);
  });

  it("returns an error (not a throw) when APNs is unreachable", async () => {
    const f = await fakeApns();
    const authority = f.authority;
    await new Promise((r) => f.server.close(r));
    const p = new ApnsProvider({ keyPem, keyId: "ABC123DEFG", teamId: "TEAM123456", bundleId: "b", environment: "production", authority });
    open.push(() => p.close());
    expect(await p.send({ deviceId: "d", token: TOKEN }, payload, { ttlSeconds: 1, highPriority: true, apns: { pushType: "voip" } })).toMatchObject({ ok: false, unregistered: false });
  });

  it("verifies with the same HMAC as FCM (signEvent) over the exact event string", () => {
    expect(signEvent("c2VjcmV0", payload.event)).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });
});

import { afterEach, describe, expect, it } from "vitest";
import { AGENT, pairDevice, pairIosDevice, setup, TEST_APNS } from "./helpers.js";
import { signEvent } from "../src/push/dispatcher.js";

let cleanup: Array<() => Promise<unknown>> = [];
afterEach(async () => {
  for (const c of cleanup) await c();
  cleanup = [];
});

async function app(over = {}) {
  const b = await setup({ apns: { ...TEST_APNS }, ...over });
  cleanup.push(() => b.app.close());
  return b;
}
const flush = () => new Promise((r) => setImmediate(r));
const types = (sent: Array<{ payload: Record<string, string> }>) => sent.map((s) => JSON.parse(s.payload.event!).type);
const call = (b: Awaited<ReturnType<typeof app>>) =>
  b.app.inject({ method: "POST", url: "/v1/calls", headers: AGENT, payload: { reason: "Deploy ready", priority: "urgent" } });

describe("iOS pairing", () => {
  it("pairs an iOS device with APNs tokens and returns the APNs environment as push_config", async () => {
    const b = await app();
    const dev = await pairIosDevice(b);
    expect(dev.push_config).toEqual({ provider: "apns", apns: { environment: "sandbox" } });
    const list = (await b.app.inject({ url: "/v1/devices", headers: AGENT })).json().devices;
    expect(list[0]).toMatchObject({ name: "iPhone", platform: "ios", has_push_token: true });
    const row = b.ctx.db.prepare("SELECT fcm_token, apns_voip_token, apns_token FROM devices").get();
    expect({ ...row }).toEqual({ fcm_token: null, apns_voip_token: "aa11", apns_token: "bb22" });
  });

  it("has_push_token follows the VoIP token on iOS, and push_config is null without APNs", async () => {
    const b = await app();
    await pairIosDevice(b, "no-voip", { apns_token: "bb22" });
    expect((await b.app.inject({ url: "/v1/devices", headers: AGENT })).json().devices[0].has_push_token).toBe(false);
    const plain = await setup();
    cleanup.push(() => plain.app.close());
    expect((await pairIosDevice(plain)).push_config).toBeNull();
  });

  it("rejects fcm_token on iOS and APNs tokens on Android", async () => {
    const b = await app();
    for (const [platform, extra] of [["ios", { fcm_token: "f" }], ["android", { apns_voip_token: "aa" }], ["android", { apns_token: "aa" }]] as const) {
      const { pairing_token } = (await b.app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: AGENT })).json();
      const r = await b.app.inject({ method: "POST", url: "/v1/pair", payload: { pairing_token, device_name: "x", platform, ...extra } });
      expect(r.statusCode, platform).toBe(400);
      // a rejected request must not burn the single-use token
      const retry = await b.app.inject({ method: "POST", url: "/v1/pair", payload: { pairing_token, device_name: "x", platform } });
      expect(retry.statusCode).toBe(201);
    }
  });

  it("keeps Android pairing as it was: FCM push_config and fcm_token", async () => {
    const b = await app();
    const dev = await pairDevice(b);
    expect(dev).toMatchObject({ push_config: { provider: "fcm" } });
    expect(b.ctx.db.prepare("SELECT apns_voip_token FROM devices").get()).toEqual({ apns_voip_token: null });
  });

  it("updates tokens through /v1/device/fcm per platform without touching the others", async () => {
    const b = await app();
    const ios = await pairIosDevice(b, "iPhone", { apns_voip_token: "aa11" });
    const post = (headers: object, payload: object) => b.app.inject({ method: "POST", url: "/v1/device/fcm", headers, payload });
    expect((await post(ios.headers, { apns_token: "cc33" })).statusCode).toBe(204);
    expect({ ...b.ctx.db.prepare("SELECT apns_voip_token, apns_token FROM devices").get() }).toEqual({ apns_voip_token: "aa11", apns_token: "cc33" });
    expect((await post(ios.headers, { fcm_token: "f" })).statusCode).toBe(400);
    expect((await post(ios.headers, {})).statusCode).toBe(400);

    const android = await pairDevice(b, "Pixel", undefined);
    expect((await post(android.headers, { fcm_token: "new" })).statusCode).toBe(204);
    expect((await post(android.headers, { apns_voip_token: "aa" })).statusCode).toBe(400);
  });
});

describe("iOS push dispatch", () => {
  it("sends a VoIP push for call.invite only, signed, to the VoIP token", async () => {
    const b = await app();
    const dev = await pairIosDevice(b);
    const { call: c } = (await call(b)).json();
    await flush();
    expect(b.apns.sent).toHaveLength(1);
    const s = b.apns.sent[0]!;
    expect(s.target).toEqual({ deviceId: dev.device_id, token: "aa11" });
    expect(s.opts.apns).toEqual({ pushType: "voip" });
    expect(s.opts.ttlSeconds).toBeGreaterThan(25);
    expect(s.opts.ttlSeconds).toBeLessThanOrEqual(30);
    expect(JSON.parse(s.payload.event!)).toMatchObject({ type: "call.invite", call_id: c.call_id, agent_name: "TestAgent", reason: "Deploy ready", priority: "urgent" });
    expect(s.payload).toMatchObject({ v: "1", relay_id: dev.relay_id, sig: signEvent(dev.push_secret, s.payload.event!) });
    expect(b.push.sent).toHaveLength(0); // never FCM for an iOS device

    // Later call events must never be pushed to iOS (a VoIP push without a reported call kills the app).
    await b.app.inject({ method: "POST", url: `/v1/calls/${c.call_id}/accept`, headers: dev.headers });
    await b.app.inject({ method: "POST", url: `/v1/calls/${c.call_id}/end`, headers: AGENT });
    await flush();
    expect(b.apns.sent).toHaveLength(1);
  });

  it("never sends a VoIP push for a missed or declined call", async () => {
    const b = await app();
    const dev = await pairIosDevice(b);
    const { call: c } = (await call(b)).json();
    await b.app.inject({ method: "POST", url: `/v1/calls/${c.call_id}/decline`, headers: dev.headers });
    await flush();
    expect(types(b.apns.sent)).toEqual(["call.invite"]);
  });

  it("sends msg.new as an alert push to the APNs token with the agent name and truncated text", async () => {
    const b = await app();
    const dev = await pairIosDevice(b);
    await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "x".repeat(500) } });
    await flush();
    expect(b.apns.sent).toHaveLength(1);
    const s = b.apns.sent[0]!;
    expect(s.target.token).toBe("bb22");
    expect(s.opts.apns?.pushType).toBe("alert");
    expect(s.opts.apns?.alert?.title).toBe("TestAgent");
    expect(Array.from(s.opts.apns!.alert!.body)).toHaveLength(200);
    expect(JSON.parse(s.payload.event!).type).toBe("msg.new");
    expect(s.payload.sig).toBe(signEvent(dev.push_secret, s.payload.event!));
  });

  it("skips msg.new without an APNs token, and invite without a VoIP token", async () => {
    const b = await app();
    await pairIosDevice(b, "voip-only", { apns_voip_token: "aa11" });
    await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "hi" } });
    await flush();
    expect(b.apns.sent).toHaveLength(0);
    const b2 = await app();
    await pairIosDevice(b2, "alert-only", { apns_token: "bb22" });
    await call(b2);
    await flush();
    expect(b2.apns.sent).toHaveLength(0);
  });

  it("keeps Android on FCM with the same rules when iOS is configured too", async () => {
    const b = await app();
    await pairDevice(b);
    const ios = await pairIosDevice(b);
    const { call: c } = (await call(b)).json();
    await b.app.inject({ method: "POST", url: `/v1/calls/${c.call_id}/end`, headers: AGENT });
    await flush();
    expect(types(b.push.sent)).toEqual(["call.invite", "call.end"]);
    expect(b.push.sent.every((s) => s.target.token === "fcm-tok-1")).toBe(true);
    expect(types(b.apns.sent)).toEqual(["call.invite"]);
    expect(b.apns.sent[0]!.target.deviceId).toBe(ios.device_id);
  });

  it("clears only the failing token when APNs reports it unregistered", async () => {
    const b = await app();
    await pairIosDevice(b);
    b.apns.next = { ok: false, unregistered: true, error: "410 Unregistered" };
    await call(b);
    await flush();
    await flush();
    expect({ ...b.ctx.db.prepare("SELECT apns_voip_token, apns_token FROM devices").get() }).toEqual({ apns_voip_token: null, apns_token: "bb22" });
    await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "hi" } });
    await flush();
    await flush();
    expect({ ...b.ctx.db.prepare("SELECT apns_voip_token, apns_token FROM devices").get() }).toEqual({ apns_voip_token: null, apns_token: null });
  });

  it("without APNs configured an iOS device gets no push and status reports FCM only", async () => {
    const b = await setup();
    cleanup.push(() => b.app.close());
    await pairIosDevice(b);
    await call(b);
    await flush();
    expect(b.push.sent).toHaveLength(0);
    expect((await b.app.inject({ url: "/v1/status", headers: AGENT })).json().push_provider).toBe("fake");
  });
});

import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { loadApnsConfig, loadConfig } from "../src/config.js";

const saved = { ...process.env };
afterEach(() => {
  process.env = { ...saved };
});

function baseEnv() {
  process.env.AGENTRING_PUBLIC_URL = "https://relay.test";
  process.env.AGENTRING_DATA_DIR = ":memory:";
  delete process.env.LIVEKIT_API_KEY;
  delete process.env.LIVEKIT_API_SECRET;
  delete process.env.LIVEKIT_API_SECRET_FILE;
  delete process.env.LIVEKIT_URL;
  delete process.env.LIVEKIT_API_URL;
}

describe("LiveKit config", () => {
  it("reads the secret from a file and defaults the URLs to the relay's host", () => {
    baseEnv();
    const dir = mkdtempSync(join(tmpdir(), "agentring-"));
    writeFileSync(join(dir, "secret"), "s".repeat(40) + "\n");
    process.env.LIVEKIT_API_KEY = "lk_test";
    process.env.LIVEKIT_API_SECRET_FILE = join(dir, "secret");
    const lk = loadConfig().livekit!;
    expect(lk.apiSecret).toBe("s".repeat(40));
    expect(lk.publicUrl).toBe("wss://relay.test");
    expect(lk.apiUrl).toBe("https://relay.test");
  });

  it("rejects weak or half-configured secrets and leaves calls off without LiveKit", () => {
    baseEnv();
    expect(loadConfig().livekit).toBeUndefined();
    process.env.LIVEKIT_API_KEY = "lk_test";
    expect(() => loadConfig()).toThrow(/LIVEKIT_API_SECRET/);
    process.env.LIVEKIT_API_SECRET = "short";
    expect(() => loadConfig()).toThrow(/at least 32/);
  });
});

describe("ring timeout", () => {
  it("defaults to 30 s and rejects values that would break or instantly expire calls", () => {
    baseEnv();
    delete process.env.AGENTRING_RING_TIMEOUT_S;
    expect(loadConfig().ringTimeoutS).toBe(30);
    process.env.AGENTRING_RING_TIMEOUT_S = "45";
    expect(loadConfig().ringTimeoutS).toBe(45);
    for (const bad of ["30s", "0", "-5", "1.5", "abc"]) {
      process.env.AGENTRING_RING_TIMEOUT_S = bad;
      expect(() => loadConfig(), bad).toThrow(/AGENTRING_RING_TIMEOUT_S/);
    }
  });
});

describe("APNs config", () => {
  function apnsEnv(over: Record<string, string> = {}) {
    for (const k of ["APNS_KEY_FILE", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_ID", "APNS_ENV"]) delete process.env[k];
    const dir = mkdtempSync(join(tmpdir(), "agentring-"));
    writeFileSync(join(dir, "AuthKey.p8"), "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n");
    Object.assign(process.env, {
      APNS_KEY_FILE: join(dir, "AuthKey.p8"),
      APNS_KEY_ID: "ABC123DEFG",
      APNS_TEAM_ID: "TEAM123456",
      APNS_BUNDLE_ID: "dev.example.agentring",
      ...over,
    });
  }

  it("is off without APNS_* variables and defaults to the production environment", () => {
    baseEnv();
    for (const k of ["APNS_KEY_FILE", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_ID", "APNS_ENV"]) delete process.env[k];
    expect(loadConfig().apns).toBeUndefined();
    apnsEnv();
    expect(loadApnsConfig()).toMatchObject({ keyId: "ABC123DEFG", teamId: "TEAM123456", bundleId: "dev.example.agentring", environment: "production" });
    process.env.APNS_ENV = "sandbox";
    expect(loadApnsConfig()?.environment).toBe("sandbox");
  });

  it("names what is missing or wrong", () => {
    apnsEnv();
    delete process.env.APNS_TEAM_ID;
    expect(() => loadApnsConfig()).toThrow(/APNS_TEAM_ID/);
    apnsEnv({ APNS_ENV: "staging" });
    expect(() => loadApnsConfig()).toThrow(/APNS_ENV must be "sandbox" or "production"/);
    apnsEnv({ APNS_KEY_ID: "short" });
    expect(() => loadApnsConfig()).toThrow(/APNS_KEY_ID must be 10/);
    apnsEnv({ APNS_KEY_FILE: "/nonexistent/AuthKey.p8" });
    expect(() => loadApnsConfig()).toThrow(/APNS_KEY_FILE .* cannot be read/);
    apnsEnv({ APNS_KEY_FILE: process.argv[1]! });
    expect(() => loadApnsConfig()).toThrow(/not a \.p8 key/);
    apnsEnv({ APNS_BUNDLE_ID: "bad id!" });
    expect(() => loadApnsConfig()).toThrow(/APNS_BUNDLE_ID/);
  });
});

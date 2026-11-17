import { readFileSync } from "node:fs";
import { connect, constants, type ClientHttp2Session, type OutgoingHttpHeaders } from "node:http2";
import { SignJWT, importPKCS8 } from "jose";
import type { ApnsConfig } from "../config.js";
import type { PushOptions, PushPayload, PushProvider, PushResult, PushTarget } from "./push-provider.js";

/**
 * Apple rejects provider tokens older than 1 h (ExpiredProviderToken) and throttles
 * generating a new one more often than every 20 min: reuse for 50 min.
 */
const TOKEN_MAX_AGE_MS = 50 * 60_000;
const REQUEST_TIMEOUT_MS = 10_000;
/** Close a session nobody used for this long; the next push reconnects. */
const SESSION_IDLE_MS = 30 * 60_000;
const MAX_BYTES = { voip: 5120, alert: 4096 } as const;
/**
 * Reasons that mean the token will never work again (`410` is handled by status).
 * `BadDeviceToken` is left out on purpose: it is also what a sandbox token gets from the
 * production host (or the reverse), so clearing it would silently drop a valid device.
 */
const DEAD_TOKEN_REASONS = new Set(["Unregistered"]);
/** UNNotificationCategory id the iOS app registers (with a text-input reply action) for msg.new alerts. */
export const ALERT_CATEGORY = "AGENTRING_MESSAGE";
const HEX_TOKEN = /^[0-9a-fA-F]{1,200}$/;

export interface ApnsProviderOptions {
  /** PKCS#8 PEM contents of the `.p8` key. */
  keyPem: string;
  keyId: string;
  teamId: string;
  bundleId: string;
  environment: "sandbox" | "production";
  /** Overridable for tests (e.g. `http://127.0.0.1:port` for a local h2c server). */
  authority?: string;
  /** Overridable for tests. */
  now?: () => number;
}

/** APNs provider over HTTP/2 with a token-based (`.p8`) key; no third-party dependencies. */
export class ApnsProvider implements PushProvider {
  readonly name = "apns";
  readonly environment: "sandbox" | "production";
  private readonly authority: string;
  private readonly now: () => number;
  private session?: ClientHttp2Session;
  private jwt?: { value: string; issuedAt: number };
  private signing?: Promise<string>;

  constructor(private readonly o: ApnsProviderOptions) {
    this.environment = o.environment;
    this.now = o.now ?? Date.now;
    this.authority = o.authority ?? (o.environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com");
  }

  static fromConfig(cfg: ApnsConfig): ApnsProvider {
    return new ApnsProvider({ ...cfg, keyPem: readFileSync(cfg.keyFile, "utf8") });
  }

  /** Signs the provider token now so a bad key shows up at startup and the first push is fast. */
  async prepare(): Promise<void> {
    await this.providerToken();
  }

  close(): void {
    this.session?.destroy();
    this.session = undefined;
  }

  private providerToken(): Promise<string> {
    if (this.jwt && this.now() - this.jwt.issuedAt < TOKEN_MAX_AGE_MS) return Promise.resolve(this.jwt.value);
    this.signing ??= this.sign().finally(() => {
      this.signing = undefined;
    });
    return this.signing;
  }

  private async sign(): Promise<string> {
    const key = await importPKCS8(this.o.keyPem, "ES256");
    const issuedAt = this.now();
    const value = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: this.o.keyId })
      .setIssuer(this.o.teamId)
      .setIssuedAt(Math.floor(issuedAt / 1000))
      .sign(key);
    this.jwt = { value, issuedAt };
    return value;
  }

  /** The shared HTTP/2 session, reconnecting if APNs closed it (GOAWAY, idle, network). */
  private getSession(): ClientHttp2Session {
    const current = this.session;
    if (current && !current.closed && !current.destroyed) return current;
    const s = connect(this.authority);
    const drop = () => {
      if (this.session === s) this.session = undefined;
    };
    s.on("error", drop);
    s.on("close", drop);
    s.on("goaway", () => {
      drop();
      s.close(); // let in-flight requests finish; new pushes use a fresh session
    });
    s.setTimeout(SESSION_IDLE_MS, () => s.close());
    this.session = s;
    return s;
  }

  private request(headers: OutgoingHttpHeaders, body: string): Promise<{ status: number; body: string }> {
    return new Promise((resolve, reject) => {
      let status = 0;
      let data = "";
      const req = this.getSession().request(headers);
      req.setEncoding("utf8");
      req.on("response", (h) => {
        status = Number(h[":status"]);
      });
      req.on("data", (c: string) => {
        data += c;
      });
      req.on("end", () => resolve({ status, body: data }));
      req.on("error", reject);
      req.on("close", () => reject(new Error("APNs stream closed before a response")));
      req.setTimeout(REQUEST_TIMEOUT_MS, () => {
        reject(new Error("APNs request timed out"));
        req.close(constants.NGHTTP2_CANCEL);
      });
      req.end(body);
    });
  }

  async send(target: PushTarget, payload: PushPayload, opts: PushOptions): Promise<PushResult> {
    const kind = opts.apns;
    if (!kind) return { ok: false, unregistered: false, error: "APNs push needs opts.apns" };
    if (!HEX_TOKEN.test(target.token)) return { ok: false, unregistered: true, error: "malformed APNs device token" };
    const body = JSON.stringify(
      kind.pushType === "alert"
        ? { aps: { alert: kind.alert ?? {}, sound: "default", category: ALERT_CATEGORY, "mutable-content": 1 }, ...payload }
        : { ...payload },
    );
    if (Buffer.byteLength(body) > MAX_BYTES[kind.pushType]) {
      return { ok: false, unregistered: false, error: `payload exceeds ${MAX_BYTES[kind.pushType]} bytes` };
    }
    const expiration = Math.floor(this.now() / 1000) + opts.ttlSeconds;

    let lastError = "";
    // One retry: the session may have died between pushes, or the provider token expired.
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const res = await this.request(
          {
            ":method": "POST",
            ":path": `/3/device/${target.token}`,
            authorization: `bearer ${await this.providerToken()}`,
            "apns-push-type": kind.pushType,
            "apns-topic": kind.pushType === "voip" ? `${this.o.bundleId}.voip` : this.o.bundleId,
            "apns-priority": kind.pushType === "voip" || opts.highPriority ? "10" : "5",
            "apns-expiration": String(expiration),
            "content-type": "application/json",
          },
          body,
        );
        if (res.status === 200) return { ok: true };
        let reason = "";
        try {
          reason = (JSON.parse(res.body) as { reason?: string }).reason ?? "";
        } catch {
          // not JSON
        }
        lastError = `${res.status} ${reason || res.body.slice(0, 200)}`.trim();
        if (res.status === 403 && /ProviderToken/.test(reason)) {
          this.jwt = undefined;
          continue;
        }
        return { ok: false, unregistered: res.status === 410 || DEAD_TOKEN_REASONS.has(reason), error: lastError };
      } catch (e) {
        lastError = String(e);
        const s = this.session;
        if (s) {
          this.session = undefined;
          s.destroy();
        }
      }
    }
    return { ok: false, unregistered: false, error: lastError };
  }
}

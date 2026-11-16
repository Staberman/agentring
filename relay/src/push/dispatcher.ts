import { createHmac } from "node:crypto";
import type { FastifyBaseLogger } from "fastify";
import type { Db } from "../db/database.js";
import type { Event } from "../protocol.js";
import type { PushOptions, PushPayload, PushProvider } from "./push-provider.js";

/** FCM data payloads are capped at 4096 bytes; leave room for the other keys. */
const MAX_EVENT_BYTES = 3000;
/**
 * APNs alerts are capped at 4096 bytes and the event JSON travels as an escaped string next to
 * the alert text, so leave generous room.
 */
const APNS_MAX_EVENT_BYTES = 1400;
const APNS_BODY_MAX_CHARS = 200;
const MESSAGE_TTL_S = 28 * 24 * 3600;
/** Call state changes only matter while a phone may still be ringing or on the call. */
const CALL_UPDATE_TTL_S = 30;
/** "Someone is on the call, you can join": long enough for a phone that was offline; the app re-checks the call. */
const CALL_JOINABLE_TTL_S = 3600;

/** Just enough of a call for push routing; `device_ids` = the phones a targeted call rings. */
export type CallLookup = (callId: string) => { direction: string; device_ids?: string[] } | undefined;

export function signEvent(pushSecret: string, eventJson: string): string {
  return createHmac("sha256", Buffer.from(pushSecret, "base64url")).update(eventJson, "utf8").digest("base64url");
}

export function buildPayload(relayId: string, pushSecret: string, event: Event, maxEventBytes = MAX_EVENT_BYTES): PushPayload {
  let json = JSON.stringify(event);
  if (event.type === "msg.new") {
    let text = event.text;
    while (Buffer.byteLength(json) > maxEventBytes && text.length > 0) {
      const overflow = Buffer.byteLength(json) - maxEventBytes;
      // Cut by code points so we never split a surrogate pair.
      const chars = Array.from(text);
      text = chars.slice(0, Math.max(0, chars.length - Math.max(overflow, 16))).join("");
      json = JSON.stringify({ ...event, text, truncated: true });
    }
  }
  return { v: "1", relay_id: relayId, event: json, sig: signEvent(pushSecret, json) };
}

interface PushRule {
  ttlSeconds: number;
  highPriority: boolean;
}

/** Which events wake the phone. Everything else is delivered over the WebSocket only. */
function ruleFor(event: Event, getCall: CallLookup): PushRule | undefined {
  switch (event.type) {
    case "msg.new":
      return event.from === "agent" ? { ttlSeconds: MESSAGE_TTL_S, highPriority: true } : undefined;
    case "call.invite":
      // Never deliver an invite after it expired: TTL = time left to ring.
      return event.direction === "agent_to_user"
        ? { ttlSeconds: Math.max(1, Math.ceil((event.expires_at - Date.now()) / 1000)), highPriority: true }
        : undefined;
    case "call.accept":
      // Lets the other phones offer "join the call" (also those whose ring ended or
      // that never got the invite). Normal priority: it doesn't need to wake a phone
      // in Doze, and a high-priority push that shows nothing (the phones still
      // ringing) gets the app's later pushes deprioritized.
      return event.by === "user" && getCall(event.call_id)?.direction === "agent_to_user"
        ? { ttlSeconds: CALL_JOINABLE_TTL_S, highPriority: false }
        : undefined;
    // call.decline is not pushed: in a group call one phone declining doesn't affect the others.
    case "call.end":
    case "call.missed":
      // Stops the ringing on every device (or tears down the call screen).
      return getCall(event.call_id)?.direction === "agent_to_user"
        ? { ttlSeconds: CALL_UPDATE_TTL_S, highPriority: true }
        : undefined;
    default:
      return undefined;
  }
}

interface IosRule {
  ttlSeconds: number;
  pushType: "voip" | "alert";
}

/**
 * Which events reach an iOS device through APNs. iOS 13+ terminates an app that receives a
 * VoIP push without reporting a call to CallKit, so a VoIP push is sent for `call.invite`
 * and for nothing else. The app is awake while a call rings and gets the other call events
 * (accept/decline/end/missed/canceled) over the WebSocket.
 */
function iosRuleFor(event: Event): IosRule | undefined {
  switch (event.type) {
    case "call.invite":
      return event.direction === "agent_to_user"
        ? { pushType: "voip", ttlSeconds: Math.max(1, Math.ceil((event.expires_at - Date.now()) / 1000)) }
        : undefined;
    case "msg.new":
      return event.from === "agent" ? { pushType: "alert", ttlSeconds: MESSAGE_TTL_S } : undefined;
    default:
      return undefined;
  }
}

interface DeviceRow {
  device_id: string;
  platform: string;
  push_secret: string;
  fcm_token: string | null;
  apns_voip_token: string | null;
  apns_token: string | null;
}

function truncate(text: string, max: number): string {
  const chars = Array.from(text);
  return chars.length <= max ? text : `${chars.slice(0, max - 1).join("")}…`;
}

export class PushDispatcher {
  constructor(
    private readonly db: Db,
    /** FCM, for Android devices. */
    private readonly provider: PushProvider | undefined,
    private readonly relayId: string,
    private readonly log: FastifyBaseLogger,
    private readonly getCall: CallLookup = () => undefined,
    /** APNs, for iOS devices. */
    private readonly apns?: PushProvider,
    private readonly agentName = "Agent",
  ) {}

  handle(event: Event): void {
    if (!this.provider && !this.apns) return;
    const rule = this.provider ? ruleFor(event, this.getCall) : undefined;
    const iosRule = this.apns ? iosRuleFor(event) : undefined;
    if (!rule && !iosRule) return;
    const devices = this.db
      .prepare(
        `SELECT device_id, platform, push_secret, fcm_token, apns_voip_token, apns_token FROM devices
         WHERE revoked_at IS NULL AND (fcm_token IS NOT NULL OR apns_voip_token IS NOT NULL OR apns_token IS NOT NULL)`,
      )
      .all() as unknown as DeviceRow[];
    // A targeted call's pushes only go to the phones it targets.
    const targets = event.type.startsWith("call.") ? this.getCall((event as { call_id: string }).call_id)?.device_ids : undefined;
    for (const d of devices) {
      if (targets && !targets.includes(d.device_id)) continue;
      if (d.platform === "ios") {
        if (this.apns && iosRule) this.sendIos(this.apns, iosRule, event, d);
        continue;
      }
      if (!this.provider || !rule || !d.fcm_token) continue;
      // The phone that joined already knows.
      if (event.type === "call.accept" && event.device_id === d.device_id) continue;
      const payload = buildPayload(this.relayId, d.push_secret, event);
      this.deliver(this.provider, d.device_id, d.fcm_token, payload, rule, event, "fcm_token");
    }
  }

  private sendIos(apns: PushProvider, rule: IosRule, event: Event, d: DeviceRow): void {
    const token = rule.pushType === "voip" ? d.apns_voip_token : d.apns_token;
    if (!token) return;
    const payload = buildPayload(this.relayId, d.push_secret, event, APNS_MAX_EVENT_BYTES);
    const opts: PushOptions = {
      ttlSeconds: rule.ttlSeconds,
      highPriority: true,
      apns:
        rule.pushType === "voip"
          ? { pushType: "voip" }
          : { pushType: "alert", alert: { title: this.agentName, body: truncate(event.type === "msg.new" ? event.text : "", APNS_BODY_MAX_CHARS) } },
    };
    this.deliver(apns, d.device_id, token, payload, opts, event, rule.pushType === "voip" ? "apns_voip_token" : "apns_token");
  }

  private deliver(
    provider: PushProvider,
    deviceId: string,
    token: string,
    payload: PushPayload,
    opts: PushOptions,
    event: Event,
    column: "fcm_token" | "apns_voip_token" | "apns_token",
  ): void {
    void provider
      .send({ deviceId, token }, payload, opts)
      .then((res) => {
        if (res.ok) {
          this.log.debug({ device: deviceId, event: event.type }, "push sent");
          return;
        }
        this.log.warn({ device: deviceId, event: event.type, error: res.error }, "push failed");
        if (res.unregistered) {
          this.db.prepare(`UPDATE devices SET ${column} = NULL WHERE device_id = ? AND ${column} = ?`).run(deviceId, token);
        }
      })
      .catch((e: unknown) => this.log.error({ err: e, device: deviceId }, "push error"));
  }
}

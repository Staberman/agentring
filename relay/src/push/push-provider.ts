/**
 * Transport-agnostic push interface. FCM (Android) and APNs (iOS) are the
 * implementations; UnifiedPush can be added later without touching the dispatcher.
 */
export interface PushTarget {
  deviceId: string;
  token: string;
}

/** String map delivered to the app (FCM `data`). See `PushData` in the OpenAPI. */
export type PushPayload = Record<string, string>;

export interface PushOptions {
  ttlSeconds: number;
  highPriority: boolean;
  collapseKey?: string;
  /** APNs only: which kind of push to send and, for alerts, what to show. */
  apns?: ApnsOptions;
}

export interface ApnsOptions {
  /** `voip` (PushKit, must be reported to CallKit) or `alert` (regular notification). */
  pushType: "voip" | "alert";
  alert?: { title: string; body: string };
}

export type PushResult = { ok: true } | { ok: false; unregistered: boolean; error: string };

export interface PushProvider {
  readonly name: string;
  send(target: PushTarget, payload: PushPayload, opts: PushOptions): Promise<PushResult>;
  /** Optional warm-up (e.g. fetch credentials) so the first real push is fast. */
  prepare?(): Promise<void>;
}

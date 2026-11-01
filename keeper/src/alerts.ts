import { log } from "./log.js";

const lastSent = new Map<string, number>();

/** Sends an alert to a Slack/Discord-compatible webhook (JSON {text, content}); always logs. Throttled per key. */
export async function alert(
  webhook: string | undefined,
  throttleMs: number,
  key: string,
  message: string,
  fields: Record<string, unknown> = {}
) {
  const now = Date.now();
  const prev = lastSent.get(key) ?? 0;
  if (now - prev < throttleMs) return;
  lastSent.set(key, now);

  log("error", `ALERT ${key}: ${message}`, fields);
  if (!webhook) return;
  try {
    await fetch(webhook, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text: `[autoLP keeper] ${message}`, content: `[autoLP keeper] ${message}` }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (e) {
    log("warn", "alert webhook failed", { error: String(e) });
  }
}

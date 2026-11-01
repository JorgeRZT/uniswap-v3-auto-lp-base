type Level = "debug" | "info" | "warn" | "error";
const order: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
const min = (process.env.LOG_LEVEL as Level) in order ? (process.env.LOG_LEVEL as Level) : "info";

/** Structured JSON logs (one line per event). BigInts are serialised as strings. Never log secrets. */
export function log(level: Level, msg: string, fields: Record<string, unknown> = {}) {
  if (order[level] < order[min]) return;
  const line = JSON.stringify(
    { ts: new Date().toISOString(), level, msg, ...fields },
    (_k, v) => (typeof v === "bigint" ? v.toString() : v)
  );
  (level === "error" ? console.error : console.log)(line);
}

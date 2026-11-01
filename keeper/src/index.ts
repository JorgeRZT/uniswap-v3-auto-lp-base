import { loadKeeperConfig } from "./config.js";
import { Keeper } from "./keeper.js";
import { log } from "./log.js";

try {
  const keeper = new Keeper(loadKeeperConfig());
  await keeper.start();
} catch (e) {
  log("error", "fatal startup error", { error: e instanceof Error ? e.message : String(e) });
  process.exit(1);
}

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    log("info", `received ${sig}, shutting down`);
    process.exit(0);
  });
}

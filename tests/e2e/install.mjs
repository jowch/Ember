// Install this checkout's ember into a temp library, for run.mjs and
// shots.mjs (#55). Returns { lib, owned }: `owned` is true when the
// library is ours to remove afterwards. EMBER_E2E_LIB set means "use the
// ember already installed there": nothing is installed. A relative
// EMBER_E2E_LIB is taken from where you ran the command (npm moves into
// tests/e2e but keeps that directory in INIT_CWD), and made absolute,
// since the servers run in other directories.

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

export function ensureLib() {
  if (process.env.EMBER_E2E_LIB) {
    return { lib: path.resolve(process.env.INIT_CWD ?? process.cwd(), process.env.EMBER_E2E_LIB), owned: false };
  }
  const lib = mkdtempSync(path.join(tmpdir(), "ember-e2e-lib-"));
  // The R that server.mjs's EMBER_RSCRIPT names, so ember is built for it.
  const rscript = process.env.EMBER_RSCRIPT ?? "Rscript";
  const r = path.basename(rscript) === rscript ? "R" : path.join(path.dirname(rscript), "R");
  console.log(`Installing ${ROOT} into ${lib}`);
  const res = spawnSync(r, ["CMD", "INSTALL", "--no-test-load", `--library=${lib}`, ROOT], { stdio: "inherit" });
  if (res.status !== 0) {
    rmSync(lib, { recursive: true, force: true });
    console.error(res.error ? `Could not run ${r}: ${res.error.message}` : "R CMD INSTALL failed");
    process.exit(1);
  }
  return { lib, owned: true };
}

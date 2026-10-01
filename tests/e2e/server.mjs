// Starts a real ember UI server (httpuv + a real worker) in a child R
// process, against a fresh copy of a fixture notebook. Mirrors
// spikes/server-worker/server3.R's shape but drives the real ember::serve()
// (docs/ui-tests.md, "Running locally" / "In CI").

import { spawn } from "node:child_process";
import { mkdtempSync, copyFileSync, mkdirSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(HERE, "fixtures");
export const SECRET = "ember-e2e-secret";

/** Copy `name` from tests/e2e/fixtures into a fresh temp directory, and
 * return its path. Each test gets its own copy so edits (and the file on
 * disk they produce) never leak between tests. */
export function tempNotebook(name = "basic.R") {
  const dir = mkdtempSync(path.join(tmpdir(), "ember-e2e-"));
  const dest = path.join(dir, name);
  copyFileSync(path.join(FIXTURES, name), dest);
  return dest;
}

/** Start `ember::serve()` in a child Rscript process, hosting
 * `notebookPaths` from the start. Resolves once the child prints its
 * "ember: listening on <url>" line (R/server.R's serve()); rejects if the
 * child exits first or nothing is heard within `timeoutMs`.
 *
 * The child's stdout/stderr are drained into a buffer as they arrive
 * (never left unread: docs/engine.md's pitfall about undrained pipes)
 * and written to a log file for CI to upload on failure. */
export async function startServer(notebookPaths, { timeoutMs = 30000, logFile } = {}) {
  const rscript = process.env.EMBER_RSCRIPT ?? "Rscript";
  const quoted = notebookPaths.map((p) => JSON.stringify(p)).join(", ");
  const expr = `ember::serve(paths = c(${quoted}), port = 0, secret = ${JSON.stringify(SECRET)})`;

  const child = spawn(rscript, ["--vanilla", "-e", expr], { stdio: ["ignore", "pipe", "pipe"] });

  let buffer = "";
  const append = (chunk) => {
    const text = chunk.toString("utf8");
    buffer += text;
    if (logFile) {
      try { appendFileSync(logFile, text); } catch { /* best effort */ }
    }
  };
  child.stdout.on("data", append);
  child.stderr.on("data", append);

  const url = await new Promise((resolve, reject) => {
    let settled = false;
    const finish = (fn, arg) => { if (!settled) { settled = true; clearTimeout(timer); fn(arg); } };
    const timer = setTimeout(
      () => finish(reject, new Error(`ember server did not start within ${timeoutMs}ms:\n${buffer}`)),
      timeoutMs);
    const check = () => {
      const m = buffer.match(/ember: listening on (\S+)/);
      if (m) finish(resolve, m[1]);
    };
    child.stdout.on("data", check);
    child.on("exit", (code) => finish(reject, new Error(`ember server exited (${code}) before listening:\n${buffer}`)));
    check();
  });

  return {
    url,
    origin: new URL(url).origin + "/",
    secret: SECRET,
    child,
    log: () => buffer,
    stop() {
      try { child.kill("SIGTERM"); } catch { /* already gone */ }
    },
  };
}

/** Where a failed test's artifacts (server log, screenshot) go, for CI to
 * upload. Created on first use. */
export function artifactsDir() {
  const dir = path.join(HERE, "test-results");
  mkdirSync(dir, { recursive: true });
  return dir;
}

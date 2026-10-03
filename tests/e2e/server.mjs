// Starts a real ember UI server (httpuv + a real worker) in a child R
// process, against a fresh copy of a fixture notebook. Mirrors
// spikes/server-worker/server3.R's shape but drives the real ember::serve()
// (docs/ui-tests.md, "Running locally" / "In CI").

import { spawn } from "node:child_process";
import { mkdtempSync, copyFileSync, mkdirSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(HERE, "fixtures");
export const SECRET = "ember-e2e-secret";

/** An ephemeral port, free right now on 127.0.0.1. `startServer()` passes
 * an explicit port rather than `port = 0`: this suite starts many Ember
 * servers at once (one per test file, run concurrently by node:test), and
 * `port = 0` now means "the stable default, 4321" (R/server.R's
 * `bind_default_port()`), which every one of them would race for. Each
 * test still exercises that default-port behaviour directly, in
 * test-server.R; this is only about keeping e2e runs from colliding with
 * each other and with the port a real interactive session would want. */
function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.unref();
    probe.on("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const port = probe.address().port;
      probe.close(() => resolve(port));
    });
  });
}

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
/** Text httpuv/libuv write to stderr when a bind loses the race
 * freePort()'s doc describes (another process took the port between the
 * probe closing and this child's own bind) -- checked case-insensitively,
 * since the exact wording isn't an R-level API this depends on. */
const BIND_FAILURE_RE = /address already in use|eaddrinuse/i;

async function startServerOnce(notebookPaths, { timeoutMs, logFile }) {
  const rscript = process.env.EMBER_RSCRIPT ?? "Rscript";
  const quoted = notebookPaths.map((p) => JSON.stringify(p)).join(", ");
  const port = await freePort();
  const expr = `ember::serve(paths = c(${quoted}), port = ${port}, secret = ${JSON.stringify(SECRET)})`;

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
    child.on("exit", (code) => {
      const err = new Error(`ember server exited (${code}) before listening:\n${buffer}`);
      err.bindFailure = BIND_FAILURE_RE.test(buffer);
      finish(reject, err);
    });
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

/** `startServerOnce()`, retried a few times on the specific bind-failure
 * race `freePort()`'s own doc already calls out: this suite starts many
 * servers at once, so two tests' probes can land on the same free port
 * moments apart, and whichever's child binds second loses. Any other
 * failure (a real startup error, a timeout) is not retried -- it means
 * something actually wrong, not a race, and retrying would only hide it
 * behind a slower, equally failing attempt. */
export async function startServer(notebookPaths, opts = {}) {
  const { timeoutMs = 30000, logFile, retries = 3 } = opts;
  let lastErr;
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      return await startServerOnce(notebookPaths, { timeoutMs, logFile });
    } catch (err) {
      if (!err.bindFailure || attempt === retries) throw err;
      lastErr = err;
    }
  }
  throw lastErr;
}

/** Where a failed test's artifacts (server log, screenshot) go, for CI to
 * upload. Created on first use. */
export function artifactsDir() {
  const dir = path.join(HERE, "test-results");
  mkdirSync(dir, { recursive: true });
  return dir;
}

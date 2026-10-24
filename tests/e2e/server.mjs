// Starts a real ember UI server (httpuv + a real worker) in a child R
// process, against a fresh copy of a fixture notebook. Mirrors
// spikes/server-worker/server3.R's shape but drives the real ember::serve()
// (docs/ui-tests.md, "Running locally" / "In CI").

import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, copyFileSync, mkdirSync, appendFileSync, rmSync, cpSync, readdirSync, renameSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";
import { addSection, stateOnStop, waitingFor } from "./waits.mjs";

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

/** A fresh folder under run.mjs's folder for the run (or the OS temp folder
 * without one), removed when this test process exits (the "exit" handler
 * below), so runs don't pile up folders there (#421, #471). */
const tempDirs = new Set();
export function tempDir(prefix) {
  // Under run.mjs's folder for the run when there is one (#471).
  const base = process.env.EMBER_E2E_RUN_DIR && existsSync(process.env.EMBER_E2E_RUN_DIR) ? process.env.EMBER_E2E_RUN_DIR : tmpdir();
  const dir = mkdtempSync(path.join(base, prefix));
  tempDirs.add(dir);
  return dir;
}

/** Copy `name` from tests/e2e/fixtures into a fresh temp directory, and
 * return its path. Each test gets its own copy so edits (and the file on
 * disk they produce) never leak between tests. */
export function tempNotebook(name = "basic.R") {
  const dir = tempDir("ember-e2e-");
  const dest = path.join(dir, name);
  copyFileSync(path.join(FIXTURES, name), dest);
  return dest;
}

/** A copy of tests/testthat/fixtures/github with each `contents/<short sha>`
 * folder renamed to the full sha `github_description_url()` asks for (the
 * one in that repository's `tarball/` starting with it), as the R tests'
 * `github_fixture_dir()` does. The folders are stored short because a
 * package tarball holds no path over 100 bytes (#244). */
export function githubFixtureDir() {
  const out = path.join(tempDir("ember-e2e-gh-"), "github");
  cpSync(path.join(HERE, "..", "testthat", "fixtures", "github"), out, { recursive: true });
  const repos = path.join(out, "repos");
  for (const user of readdirSync(repos)) {
    for (const repo of readdirSync(path.join(repos, user))) {
      const contents = path.join(repos, user, repo, "contents");
      if (!existsSync(contents)) continue;
      const shas = readdirSync(path.join(repos, user, repo, "tarball"));
      for (const short of readdirSync(contents)) {
        const full = shas.filter((sha) => sha.startsWith(short));
        if (full.length !== 1) throw new Error(`no single tarball sha starts with ${short} in ${user}/${repo}`);
        renameSync(path.join(contents, short), path.join(contents, full[0]));
      }
    }
  }
  return out;
}

/** Start `ember::serve()` in a child Rscript process, hosting
 * `notebookPaths` from the start. Resolves once the child prints its
 * "ember: listening on <url>" line (R/server.R's serve()); rejects if the
 * child exits first or nothing is heard within `timeoutMs` (0, the
 * default: no limit; a server that never says it is listening shows up,
 * with its log, in the report waits.mjs writes when the runner stops the
 * file).
 *
 * The child's stdout/stderr are drained into a buffer as they arrive
 * (never left unread: docs/engine.md's pitfall about undrained pipes)
 * and written to a log file for CI to upload on failure. */
/** Text httpuv/libuv write to stderr when a bind loses the race
 * freePort()'s doc describes (another process took the port between the
 * probe closing and this child's own bind) -- checked case-insensitively,
 * since the exact wording isn't an R-level API this depends on. */
const BIND_FAILURE_RE = /address already in use|eaddrinuse/i;

/** Every server child this test process started that hasn't exited yet,
 * killed when node exits: a test that fails or times out before its
 * `stop()` would otherwise leave its R process running. */
const liveChildren = new Set();
process.on("exit", () => {
  for (const child of liveChildren) {
    try { child.kill("SIGKILL"); } catch { /* already gone */ }
  }
  // After the kills: a folder a server still had open would not go.
  for (const dir of tempDirs) {
    try { rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }); } catch { /* left for the OS */ }
  }
});
// A signal ends the process without "exit" unless something handles it:
// Ctrl+C, a stop, or the terminal or console window closing (SIGHUP, also
// what Node emits on Windows for a closed console), so the folders still go.
// The runner's stop for a file that ran too long is a SIGTERM, so first
// say what the file was waiting for (waits.mjs).
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) {
  process.once(signal, async () => { await stateOnStop(); process.exit(code); });
}

/** Every server this process started that is still running, for the
 * report of what a stopped test was waiting for (waits.mjs): whether it
 * said it was listening, and the end of its log. */
const servers = new Set();
addSection(() => [...servers].map((s) => {
  const tail = s.log().trimEnd().split("\n").slice(-15).map((l) => `    ${l}`).join("\n");
  return `server for ${s.notebooks}${s.listening ? "" : ", not listening yet"}; its log ends:\n${tail}`;
}).join("\n"));

/** `R_LIBS` for a server child: the library run.mjs installed this
 * checkout into, ahead of anything already on `R_LIBS`, so `ember::`
 * loads the code under test and not whatever the default library has
 * (#55). The worker finds ember through the server's own install
 * (`system.file()`, R/shell.R), so it follows. */
function emberLibs() {
  const lib = process.env.EMBER_E2E_LIB;
  if (!lib) {
    throw new Error("EMBER_E2E_LIB is not set: run the browser tests with `npm test` (or `node run.mjs <files>`), " +
      "which installs this checkout into a temp library, or set it to a library holding the ember to test");
  }
  return [path.resolve(lib), process.env.R_LIBS].filter(Boolean).join(path.delimiter);
}

/** The Rscript to start servers with: EMBER_RSCRIPT, or Rscript from the
 * PATH. On Windows both are usually R's `bin\Rscript.exe`, a front end
 * that runs the real `bin\x64\Rscript.exe` through cmd.exe. `stop()`
 * would then end only the front end, leaving the server running with its
 * port and its worker (#219). So R is asked once for the real one. */
let realRscript = null;
function serverRscript() {
  const rscript = process.env.EMBER_RSCRIPT ?? "Rscript";
  if (process.platform !== "win32") return rscript;
  if (realRscript === null) {
    const res = spawnSync(rscript, ["--vanilla", "-e", "cat(file.path(R.home('bin'), 'Rscript.exe'))"], { encoding: "utf8" });
    const found = res.status === 0 && res.stdout.trim();
    realRscript = found ? res.stdout.trim() : rscript;
    if (!found) console.error(`server.mjs: could not ask ${rscript} for R's own Rscript.exe; using it as is, so a stopped server may keep running (#219)`);
  }
  return realRscript;
}

async function startServerOnce(notebookPaths, { timeoutMs, logFile, installerScript, cwd, port: fixedPort, secret = SECRET, repos, cacheDir, askAbove }) {
  const rscript = serverRscript();
  const quoted = notebookPaths.map((p) => JSON.stringify(p)).join(", ");
  const port = fixedPort ?? await freePort();
  // Set before `ember::serve()` starts: `installer_script()` (R/library.R)
  // reads the option when `library.R` builds each install's command, so it
  // must already be set the first time a notebook tries to install.
  let prelude = installerScript ? `options(ember.installer_script = ${JSON.stringify(installerScript)}); ` : "";
  // A test that seeds the cache itself (clean-up.test.mjs) names it; the
  // folder is the test's, so it is not removed here.
  if (cacheDir) prelude += `options(ember.cache_dir = ${JSON.stringify(cacheDir)}); `;
  // Read when each notebook opens (`new_state()`), so set first too.
  if (askAbove != null) prelude += `options(ember.ask_above = ${askAbove}); `;
  let expr;
  let cache = null;
  if (repos) {
    // The notebooks resolve against fixture repositories (`ember_repos()`
    // arguments, e.g. `file://` folders), so `serve()` doesn't open them
    // itself: they are opened with those repos and hosted in `on_ready`,
    // before the server answers any request. Their indexes go to a cache
    // of their own, never the shared one: a fixture's index is saved under
    // the same key ("cran/2026-09-01") a real one would be.
    if (!cacheDir) {
      cache = mkdtempSync(path.join(tmpdir(), "ember-e2e-cache-"));
      prelude += `options(ember.cache_dir = ${JSON.stringify(cache)}); `;
    }
    const args = Object.entries(repos).map(([k, v]) => `${k} = ${v === null ? "NA" : JSON.stringify(v)}`).join(", ");
    const onReady = `function(server) for (p in c(${quoted})) ember::host_notebook(server, ember::open_notebook(p, repos = ember::ember_repos(${args})), owned = TRUE)`;
    expr = `${prelude}ember::serve(port = ${port}, secret = ${JSON.stringify(secret)}, on_ready = ${onReady})`;
  } else {
    expr = `${prelude}ember::serve(paths = c(${quoted}), port = ${port}, secret = ${JSON.stringify(secret)})`;
  }

  // tools::R_user_dir("ember", "data") (recent.R's recent-notebooks file)
  // honours this environment variable: each server gets its own temp
  // folder, so this suite never touches the real one or lets two test
  // servers share a recent-notebooks file.
  const dataDir = tempDir("ember-e2e-data-");
  const child = spawn(rscript, ["--vanilla", "-e", expr], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, R_USER_DATA_DIR: dataDir, R_LIBS: emberLibs() },
    // `new_server()`'s `start_dir` (the start page's default Folder for a
    // new notebook) is wherever this child's cwd is; default to the
    // parent's own, same as spawn()'s own default, so tests that care
    // (start-page.test.mjs) can pin it to a fixture folder instead.
    cwd,
  });
  liveChildren.add(child);
  child.on("exit", () => liveChildren.delete(child));
  // The private index cache goes with the server that used it. `stop()`
  // interrupts the server, whose `serve()` then closes its notebooks and
  // so ends their installs and index fetches before it exits (#141): a
  // removal that still fails means something the server started outlived
  // it, a leak, and its throw here fails the test file (#138).
  // `maxRetries` covers only the moment between a killed job's last
  // write and its exit.
  if (cache) child.on("exit", () => rmSync(cache, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));
  // Unreferenced so a test file whose test failed before `stop()` still
  // lets node exit, which kills the child through the "exit" handler.
  child.unref();
  child.stdout.unref();
  child.stderr.unref();

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
  const entry = { notebooks: notebookPaths.map((p) => path.basename(p)).join(", "), log: () => buffer, listening: false };
  servers.add(entry);
  child.on("exit", () => servers.delete(entry));

  const url = await waitingFor(`the server for ${entry.notebooks} says it is listening`, new Promise((resolve, reject) => {
    let settled = false;
    const finish = (fn, arg) => { if (!settled) { settled = true; clearTimeout(timer); fn(arg); } };
    // 0, the default: no timer of its own; the runner bounds the wait.
    const timer = timeoutMs > 0 ? setTimeout(
      () => finish(reject, new Error(`ember server did not start within ${timeoutMs}ms:\n${buffer}`)),
      timeoutMs) : null;
    const check = () => {
      const m = buffer.match(/ember: listening on (\S+)/);
      if (m) { entry.listening = true; finish(resolve, m[1]); }
    };
    child.stdout.on("data", check);
    child.on("exit", (code) => {
      const err = new Error(`ember server exited (${code}) before listening:\n${buffer}`);
      err.bindFailure = BIND_FAILURE_RE.test(buffer);
      finish(reject, err);
    });
    check();
  }));

  return {
    url,
    origin: new URL(url).origin + "/",
    secret,
    port,
    child,
    log: () => buffer,
    /** SIGINT, as Ctrl-C would, so `serve()` closes its notebooks and
     * ends their jobs on the way out; SIGKILL if the child is still alive
     * 2 s later. Resolves once it has exited. */
    stop() {
      if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
      // Referenced again, so node waits for the child's exit, and the
      // cleanup above, even when the test doesn't await this.
      child.ref();
      return new Promise((resolve) => {
        const timer = setTimeout(() => {
          try { child.kill("SIGKILL"); } catch { /* already gone */ }
        }, 2000);
        child.once("exit", () => { clearTimeout(timer); resolve(); });
        try { child.kill("SIGINT"); } catch { clearTimeout(timer); resolve(); }
      });
    },
  };
}

/** `startServerOnce()`, retried a few times on the specific bind-failure
 * race `freePort()`'s own doc already calls out: this suite starts many
 * servers at once, so two tests' probes can land on the same free port
 * moments apart, and whichever's child binds second loses. Any other
 * failure (a real startup error, a timeout) is not retried -- it means
 * something actually wrong, not a race, and retrying would only hide it
 * behind a slower, equally failing attempt.
 *
 * `port` and `secret` pin what the server uses, for a test that restarts
 * a server at the same address with a new secret. `repos` (an object of
 * `ember_repos()` arguments, `null` for `NA`) opens the notebooks against
 * those repositories instead of the real ones. `cacheDir` points the
 * server's cache (`options(ember.cache_dir)`) at a folder the test owns.
 * `askAbove` sets `options(ember.ask_above)`: the bytes of large downloads
 * an install asks about first (#37). */
export async function startServer(notebookPaths, opts = {}) {
  const { timeoutMs = 0, logFile, retries = 3, installerScript, cwd, port, secret, repos, cacheDir, askAbove } = opts;
  let lastErr;
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      return await startServerOnce(notebookPaths, { timeoutMs, logFile, installerScript, cwd, port, secret, repos, cacheDir, askAbove });
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

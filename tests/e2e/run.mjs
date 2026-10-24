// `npm test`: installs this checkout's ember into a temp library, then
// runs the browser tests against it (#55). Without this, every server the
// tests start would load whatever ember Rscript's default library holds,
// which is often not the code under test.
//
// Usage: node run.mjs [test files...]   (default: tests/*.test.mjs)
//
// The library is installed once per run, not once per test file:
// node:test runs each file in its own process. Its path reaches
// server.mjs through EMBER_E2E_LIB, which every server child puts first
// on R_LIBS. Set EMBER_E2E_LIB yourself to skip the install and test an
// ember you installed there.

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ensureLib } from "./install.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const { lib, owned: ownLib } = ensureLib();
// One folder for the run, which every test file's temp folders go under
// (server.mjs's `tempDir()`), removed once the runner has exited. A file
// the runner stops at its time limit is ended outright on Windows, so
// its own exit handler never removes its folders (#471).
const runDir = mkdtempSync(path.join(tmpdir(), "ember-e2e-run-"));
// The OS temp folder is the run folder too, for whatever else a stopped
// file leaves there: the servers' private caches, R's own Rtmp folders,
// Chromium's profiles (TMPDIR on Unix, TMP and TEMP on Windows).
const env = { ...process.env, EMBER_E2E_LIB: lib, EMBER_E2E_RUN_DIR: runDir, TMPDIR: runDir, TMP: runDir, TEMP: runDir };
const files = process.argv.slice(2);
const tests = files.length ? files
  : readdirSync(path.join(HERE, "tests")).filter((f) => f.endsWith(".test.mjs")).sort().map((f) => path.join("tests", f));

// Pass a stop on to whichever child is running, the warm-up or the test
// runner, and wait for it to finish, so the library is removed after the
// servers using it are gone.
let child = null;
let stopped = false;
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, () => { stopped = true; child?.kill(signal); });
// What a test file was waiting for when its process ended with a wait
// still pending (waits.mjs): the runner's stop for a file that ran too
// long, or a crash. Lists from an earlier run go first.
const RESULTS = path.join(HERE, "test-results");
const waitLists = () => (existsSync(RESULTS) ? readdirSync(RESULTS).filter((f) => /^waiting-.*\.txt$/.test(f)) : []);
for (const f of waitLists()) rmSync(path.join(RESULTS, f), { force: true });
const finish = (code, signal) => {
  for (const f of waitLists()) {
    console.log(`\n== test-results/${f}\n${readFileSync(path.join(RESULTS, f), "utf8")}`);
  }
  if (ownLib) rmSync(lib, { recursive: true, force: true });
  // A file something still holds is left for the OS, not a failed run.
  try { rmSync(runDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { /* left for the OS */ }
  process.exit(code ?? (signal ? 1 : 0));
};

// The warm-up (warmup.mjs, #417) runs first, in a process of its own like
// each test file, so server.mjs's exit and signal handlers aren't this
// one's. Its result doesn't decide the run's; a stop during it ends the run.
child = spawn(process.execPath, ["warmup.mjs"], { cwd: HERE, stdio: "inherit", env });
child.on("exit", () => {
  if (stopped) return finish(1);
  child = spawn(process.execPath,
    ["--test", "--test-timeout=300000", "--test-concurrency=3", ...tests],
    { cwd: HERE, stdio: "inherit", env });
  child.on("exit", finish);
});

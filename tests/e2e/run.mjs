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

import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, "..", "..");

let lib = process.env.EMBER_E2E_LIB;
let ownLib = false;
if (!lib) {
  lib = mkdtempSync(path.join(tmpdir(), "ember-e2e-lib-"));
  ownLib = true;
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
}

const files = process.argv.slice(2);
const tests = files.length ? files
  : readdirSync(path.join(HERE, "tests")).filter((f) => f.endsWith(".test.mjs")).sort().map((f) => path.join("tests", f));
const child = spawn(process.execPath,
  ["--test", "--test-timeout=300000", "--test-concurrency=3", ...tests],
  { cwd: HERE, stdio: "inherit", env: { ...process.env, EMBER_E2E_LIB: lib } });

// Pass a stop on to the test runner and wait for it to finish, so the
// library is removed after the servers using it are gone.
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => child.kill(signal));
child.on("exit", (code, signal) => {
  if (ownLib) rmSync(lib, { recursive: true, force: true });
  process.exit(code ?? (signal ? 1 : 0));
});

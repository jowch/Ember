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
import { readdirSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ensureLib } from "./install.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const { lib, owned: ownLib } = ensureLib();

const files = process.argv.slice(2);
const tests = files.length ? files
  : readdirSync(path.join(HERE, "tests")).filter((f) => f.endsWith(".test.mjs")).sort().map((f) => path.join("tests", f));
const child = spawn(process.execPath,
  ["--test", "--test-timeout=300000", "--test-concurrency=3", ...tests],
  { cwd: HERE, stdio: "inherit", env: { ...process.env, EMBER_E2E_LIB: lib } });

// Pass a stop on to the test runner and wait for it to finish, so the
// library is removed after the servers using it are gone.
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, () => child.kill(signal));
child.on("exit", (code, signal) => {
  if (ownLib) rmSync(lib, { recursive: true, force: true });
  process.exit(code ?? (signal ? 1 : 0));
});

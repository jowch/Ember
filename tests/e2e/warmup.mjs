// One server, one browser, one notebook and one run before the tests start,
// with each phase's time printed (#417). On a fresh Windows runner the
// first tests of a run, three files starting at once, waited over 30 s for
// a notebook's first cell or its first run. The times printed here say
// which start is slow. It is a measurement, not a fix: if a slow phase is
// Ember's (the server's start or the first page load), a person's first
// open is slow too, and that is the bug to fix (#417). Nothing here has a
// timeout of its own: the job's timeout bounds it. run.mjs runs it.

import { writeFileSync } from "node:fs";
import path from "node:path";
import { startServer, tempDir } from "./server.mjs";
import { launchBrowser, newPage, openNotebook, waitIdle } from "./browser.mjs";

const NOTEBOOK = `### An Ember notebook ###
# /// environment
# ember_version = "0.0.0.9000"
# r_version = "4.6.1"
# snapshot = "2026-01-01"
# ///

# %% id=A
1 + 1

# /// cell order
# A
# ///
`;

async function warmUp() {
  const t0 = Date.now();
  const secs = (from) => ((Date.now() - from) / 1000).toFixed(1);
  const notebook = path.join(tempDir("ember-e2e-warmup-"), "warmup.R");
  writeFileSync(notebook, NOTEBOOK);
  const times = [];
  let server, browser;
  const phase = async (name, fn) => {
    const t = Date.now();
    const value = await fn();
    times.push(`${name} ${secs(t)} s`);
    return value;
  };
  try {
    server = await phase("server listening", () => startServer([notebook], { timeoutMs: 0 }));
    browser = await phase("browser", () => launchBrowser());
    const page = await newPage(browser);
    await phase("first cell", () => openNotebook(page, server.origin, server.secret, notebook));
    await phase("first run", async () => {
      await page.locator("#ember-safe-preview button").click({ timeout: 0 });
      await waitIdle(page);
    });
    const line = `warm-up: ${times.join(", ")} (${secs(t0)} s in all)`;
    // On GitHub Actions, also a notice on the run's summary page.
    console.log(process.env.GITHUB_ACTIONS ? `::notice title=e2e warm-up::${line}` : line);
  } catch (e) {
    // The tests still run and report: if the warm-up can't open and run a
    // notebook, they fail too, with their own messages.
    console.error(`warm-up failed after ${secs(t0)} s (${times.join(", ")}): ${e.message}`);
  } finally {
    await browser?.close();
    await server?.stop();
  }
}

// server.mjs unrefs its child and pipes, so a test file whose test failed
// can still exit; here nothing else would keep node waiting on them.
const alive = setInterval(() => {}, 1000);
await warmUp();
clearInterval(alive);

// Screenshots of a notebook as a person sees it, for looking at a UI
// change before and after (the verify skill, .claude/skills/verify), plus
// layout-check.mjs's problems on each one.
//
// Usage (from tests/e2e, after `npm ci`):
//   node shots.mjs [notebook] [options]
//
//   notebook       a fixture name (fixtures/<name>) or a path to any .R
//                  notebook. A copy is opened, so the file is never
//                  changed. Default: ui-sweep.R.
//   --run          click "Run this notebook" and wait for every cell.
//   --widths LIST  comma-separated, default 600,900,1440.
//   --dark         also take each width in dark mode.
//   --mac          ⌘ shortcut labels (default: Ctrl, as on Linux/Windows).
//   --full         full-page screenshots (default: the first screen).
//   --out DIR      default test-results/shots.
//
// Prints each file it saved and the layout problems found at each width,
// and exits 1 if there were any. Like run.mjs it installs this checkout
// into a temp library first, unless EMBER_E2E_LIB names one.
// EMBER_BROWSER=webkit takes them in WebKit.

import path from "node:path";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { ensureLib } from "./install.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    run: { type: "boolean" }, dark: { type: "boolean" }, mac: { type: "boolean" }, full: { type: "boolean" },
    widths: { type: "string", default: "600,900,1440" },
    out: { type: "string", default: path.join(HERE, "test-results", "shots") },
  },
});

const { lib, owned } = ensureLib();
process.env.EMBER_E2E_LIB = lib;
// Imported after EMBER_E2E_LIB is set: server.mjs reads it per server.
const { startServer, tempNotebook } = await import("./server.mjs");
const { launchBrowser, newPage, openNotebook } = await import("./browser.mjs");
const { pageProblems, emulatePlatform, formatProblems } = await import("./layout-check.mjs");

const arg = positionals[0] ?? "ui-sweep.R";
let notebook;
if (existsSync(path.join(HERE, "fixtures", arg))) notebook = tempNotebook(arg);
else {
  const { mkdtempSync, copyFileSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  notebook = path.join(mkdtempSync(path.join(tmpdir(), "ember-shots-")), path.basename(arg));
  copyFileSync(path.resolve(arg), notebook);
}

mkdirSync(values.out, { recursive: true });
const server = await startServer([notebook], { logFile: path.join(values.out, "server.log") });
const browser = await launchBrowser();
let failed = false;
try {
  const page = await newPage(browser);
  await emulatePlatform(page, values.mac ? "mac" : "other");
  await openNotebook(page, server.origin, server.secret, notebook);
  if (values.run) {
    await page.locator("#ember-safe-preview button").click();
    await page.waitForFunction(() => !document.querySelector("#ember-safe-preview"), null, { timeout: 30000 });
    await page.waitForTimeout(500);
    await page.waitForFunction(() => document.querySelectorAll("pluto-cell.running, pluto-cell.queued").length === 0,
      null, { timeout: 120000 });
  }
  const stem = path.basename(notebook, ".R");
  for (const width of values.widths.split(",").map(Number)) {
    for (const scheme of values.dark ? ["light", "dark"] : ["light"]) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.setViewportSize({ width, height: 900 });
      await page.waitForTimeout(300);
      const problems = await pageProblems(page);
      const file = path.join(values.out, `${stem}-${width}-${scheme}${values.mac ? "-mac" : ""}.png`);
      await page.screenshot({ path: file, fullPage: !!values.full });
      console.log(file);
      if (problems.length) {
        failed = true;
        console.log(formatProblems(problems));
      }
    }
  }
  if (page.problems.length) console.log("browser errors:\n  " + page.problems.join("\n  "));
} finally {
  await browser.close();
  server.stop();
  if (owned) rmSync(lib, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);

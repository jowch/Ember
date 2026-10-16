// The Status tab (ui-3.md, Status) agrees with the header, and its
// Restart R only restarts: it never runs a notebook that is still in safe
// preview (#29, #32).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

// #32: after the server refuses the page's old key, the header says Ember
// restarted; the Status tab must say the same, not "Reconnecting".
test("status tab: says Ember restarted once the server refuses the page's key (#32)", async (t) => {
  const notebook = tempNotebook();
  const logFile = path.join(artifactsDir(), "status-tab-key-refused.server.log");
  const first = await startServer([notebook], { logFile, secret: "first-session-secret" });
  let second = null;
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); first.stop(); second?.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, first.origin, first.secret, notebook);
  await page.locator("#ember-r-status").click();
  await page.waitForSelector("#ember-status-tab");

  await first.stop();
  second = await startServer([notebook], { logFile, port: first.port, secret: "second-session-secret" });

  await page.getByRole("alertdialog").waitFor({ timeout: 30000 });
  await page.locator("#ember-r-status", { hasText: "Ember restarted" }).waitFor({ timeout: 30000 });
  assert.match(await page.locator("#ember-status-tab .ember-status-state").innerText(), /Ember restarted/);
});

// #29: in safe preview R hasn't started, so there is nothing to restart.
// The server maps restart_process to "run every cell" in preview (that is
// the banner's "Run this notebook"), so an enabled Restart R here would run
// code the user hasn't allowed yet.
test("status tab: Restart R is off in safe preview and runs nothing (#29)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-tab-preview.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview").waitFor({ state: "visible" });
  await page.locator("#ember-r-status").click();
  const restart = page.locator("#ember-status-restart");
  await restart.waitFor();
  assert.equal(await restart.isDisabled(), true, "Restart R is disabled in safe preview");

  // Once the banner's "Run this notebook" starts R, Restart R is on again.
  // (The open panel covers the banner at this width; the R status button
  // toggles it shut.)
  await page.locator("#ember-r-status").click();
  await page.locator("#ember-status-tab").waitFor({ state: "detached" });
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output", { timeout: 30000 });
  await page.locator("#ember-r-status").click();
  await page.waitForFunction(() => document.querySelector("#ember-status-restart")?.disabled === false, null, { timeout: 30000 });
  assertNoProblems(page);
});

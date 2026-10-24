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

  await page.getByRole("alertdialog").waitFor();
  await page.locator("#ember-r-status", { hasText: "Ember restarted" }).waitFor();
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
  // (At newPage()'s 1200px the open panel is a slide-over that covers the
  // banner; the R status button toggles it shut.)
  await page.locator("#ember-r-status").click();
  await page.locator("#ember-status-tab").waitFor({ state: "detached" });
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output");
  await page.locator("#ember-r-status").click();
  await page.waitForFunction(() => document.querySelector("#ember-status-restart")?.disabled === false);
  assertNoProblems(page);
});

// #29, while the page loads: the Status tab can be on screen (the last tab
// used, docked from 1240px) and the socket up before the first notebook
// state says the notebook is in safe preview. Restart R stays off until it
// does. Here the server's messages after the first are held until the test
// has looked, so the window is as wide as the test needs.
test("status tab: Restart R stays off while the page doesn't know R's state yet (#29)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-tab-load.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
  await context.addInitScript(() => {
    localStorage.setItem("ember_panel_tab", "process");
    localStorage.setItem("ember_panel_open", "true");
  });
  const page = await context.newPage();
  let held = [];
  let seen = 0;
  let to_page = null;
  await page.routeWebSocket(/.*/, (ws) => {
    const srv = ws.connectToServer();
    to_page = ws;
    ws.onMessage((m) => srv.send(m));
    srv.onMessage((m) => {
      seen += 1;
      if (seen === 1 || held == null) ws.send(m); else held.push(m);
    });
  });
  await page.goto(`${server.origin}open?path=${encodeURIComponent(notebook)}&secret=${server.secret}`);

  const restart = page.locator("#ember-status-restart");
  await restart.waitFor();
  assert.equal(await page.evaluate(() => window.editor_state?.notebook?.ember?.process ?? null), null, "the notebook state is still held back");
  assert.equal(await restart.isDisabled(), true, "Restart R is off before the page knows R's state");

  const release = held;
  held = null;
  for (const m of release) to_page.send(m);
  await page.locator("#ember-safe-preview").waitFor({ state: "visible" });
  assert.equal(await restart.isDisabled(), true, "and stays off in safe preview");
  await context.close();
});

// #51: Interrupt and Restart R are Panel3's side-panel buttons, 30 px tall
// like the Packages tab's, not the header's 32 px.
test("status tab: Interrupt and Restart R are the side panel's 30 px buttons (#51)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-tab-buttons.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-r-status").click();
  await page.waitForSelector("#ember-status-tab .ember-btn");
  const heights = await page.locator("#ember-status-tab .ember-btn").evaluateAll((els) => els.map((el) => el.getBoundingClientRect().height));
  assert.equal(heights.length, 2, "Interrupt and Restart R");
  assert.deepEqual(heights, [30, 30]);
  assertNoProblems(page);
});

// A request whose socket closes before its reply, or that is sent while
// the socket is closed, fails rather than waiting forever (#584). The
// page's socket is routed through the test (routeWebSocket), so a frame
// can be dropped and the socket closed at a chosen moment; the page then
// reconnects on its own.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector, waitIdle } from "../browser.mjs";

const LOST = "Lost the connection to Ember before it answered";

// Opens `notebook` with its socket routed: `cut(type)` makes the next
// frame the page sends whose bytes include `type` close the socket
// instead of reaching the server; `close()` closes it now.
async function routed(t, name) {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), `lost-reply-${name}.server.log`) });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });
  const page = await newPage(browser);
  let cut_on = null;
  let to_page = null;
  await page.routeWebSocket(/.*/, (ws) => {
    const srv = ws.connectToServer();
    to_page = ws;
    ws.onMessage((m) => {
      if (cut_on != null && Buffer.from(m).includes(cut_on)) {
        cut_on = null;
        ws.close();
      } else srv.send(m);
    });
    srv.onMessage((m) => ws.send(m));
  });
  await openNotebook(page, server.origin, server.secret, notebook);
  return { page, notebook, cut: (type) => (cut_on = type), close: () => to_page.close() };
}

const connected = (page) => page.waitForFunction(() => window.ember_connection?.state === "connected");

async function openMoveDialog(page) {
  await page.locator("#ember-file-name").click();
  const dialog = page.locator("dialog.ember-dialog[open]");
  await dialog.waitFor({ state: "visible" });
  await dialog.locator("#ember-move-name").fill("renamed");
  return dialog;
}

test("move dialog: Save whose socket closes before the reply says so, and can be tried again (#584)", async (t) => {
  const { page, notebook, cut } = await routed(t, "in-flight");
  const dialog = await openMoveDialog(page);
  cut("ember_move_notebook");
  await dialog.getByRole("button", { name: "Save" }).click();
  await dialog.locator(".ember-dialog-error", { hasText: LOST }).waitFor();
  assert.equal(await dialog.getByRole("button", { name: "Save" }).isEnabled(), true, "Save works again");
  assert.equal(await dialog.getByRole("button", { name: "Cancel" }).isEnabled(), true, "Cancel works again");

  // Once reconnected, the same Save moves the file.
  await connected(page);
  await dialog.getByRole("button", { name: "Save" }).click();
  await dialog.waitFor({ state: "hidden" });
  await page.waitForFunction(() => document.title === "renamed.R — Ember");
  assert.equal(fs.existsSync(path.join(path.dirname(notebook), "renamed.R")), true);
});

test("move dialog: Save while the socket is closed says so (#584)", async (t) => {
  const { page, close } = await routed(t, "closed");
  const dialog = await openMoveDialog(page);
  close();
  // Clicked in the same task that sees the socket closed and the page
  // waiting to reconnect, so the click can't land after the reconnect.
  await page.evaluate(() => new Promise((resolve) => {
    const tick = () => {
      if (window.ember_connection.state !== "waiting") return requestAnimationFrame(tick);
      [...document.querySelectorAll("dialog.ember-dialog[open] button")].find((b) => b.textContent.trim() === "Save").click();
      resolve();
    };
    tick();
  }));
  await dialog.locator(".ember-dialog-error", { hasText: LOST }).waitFor();
  assert.equal(await dialog.getByRole("button", { name: "Save" }).isEnabled(), true, "Save works again");
});

test("an edit whose socket closes before the reply doesn't hold up the edits after it (#584)", async (t) => {
  const { page, cut } = await routed(t, "update");
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output");
  await waitIdle(page);
  cut("update_notebook");
  // Running sends the edit (update_notebook), and that frame closes the socket.
  await setCellCode(page, "A", "x <- 1:20");
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction(() => window.ember_connection?.state !== "connected");
  await connected(page);

  await setCellCode(page, "B", "sum(1:10) + 1000");
  await runCell(page, "B");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("1055"),
    cellSelector("B") + " pluto-output");
  assertNoProblems(page);
});

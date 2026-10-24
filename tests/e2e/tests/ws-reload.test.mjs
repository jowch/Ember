// #385: a reload while a websocket message is being read. WebKit delivered
// each message as a Blob, and PlutoConnection.js read it later; a reload
// that interrupted the read failed it, logging "Failed to unpack message"
// and a page error. Messages now arrive as ArrayBuffers, already read.
// CI runs this file in WebKit too.

import { test } from "node:test";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell } from "../browser.mjs";

const loaded = (page) => page.waitForFunction(() => !document.querySelector("pluto-editor")?.classList.contains("loading"));

test("websocket: no message is read as a Blob, so a failed Blob read can't lose one (#385)", async (t) => {
  const notebook = tempNotebook("ws-reload.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ws-reload-blob.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // Every Blob read fails, the way WebKit fails one that a reload
  // interrupts. A message read as a Blob would then fail to unpack.
  await page.context().addInitScript(() => {
    Blob.prototype.arrayBuffer = function () {
      return Promise.reject(new DOMException("The I/O read operation failed.", "NotReadableError"));
    };
  });
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.reload();
  await loaded(page);
  assertNoProblems(page);
});

test("websocket: reloading while a cell streams output logs no errors (#385)", async (t) => {
  const notebook = tempNotebook("ws-reload.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ws-reload.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "STREAM");
  await page.waitForFunction(() => document.getElementById("STREAM")?.classList.contains("running"));
  // Each reload lands while the cell is still printing, so messages are
  // arriving as the page goes away.
  for (let i = 0; i < 4; i++) {
    // A message arrives after the load, so the reload lands while more are
    // coming; once the run has ended there are none left to wait for.
    const last = await page.evaluateHandle(() => window.pluto_get_message_log().at(-1));
    await page.waitForFunction((last) => window.pluto_get_message_log().at(-1) !== last
      || !window.editor_state?.notebook?.cell_results?.STREAM?.running, last);
    await page.reload();
    await loaded(page);
  }
  assertNoProblems(page);
});

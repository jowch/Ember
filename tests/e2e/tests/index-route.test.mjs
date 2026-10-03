// review4 item 10: "/" used to serve Pluto's vendored Julia welcome page
// (frontend/index.html, served automatically by httpuv's static handler for
// the bare "/" path) instead of Ember's own start page.
// ui-3-plan.md, piece 4, "Create, open, and the start page": "/" now
// serves start.html, which renders its "My notebooks" list (open, then
// recent) from the `ember_start_page` request once the page's websocket
// connects, rather than from server-rendered HTML.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage } from "../browser.mjs";

test('index: "/" shows Ember\'s own start page, not Pluto\'s Julia welcome page', async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "index-route.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  const resp = await page.goto(`${server.url}`);
  assert.equal(resp.status(), 200);

  // The open notebook's row is rendered by StartPage.js from the
  // ember_start_page reply, after the page's websocket connects -- wait
  // for the script-rendered link rather than asserting on first paint.
  const editLink = page.locator('a[href*="edit?id="]').first();
  await editLink.waitFor({ state: "visible", timeout: 10000 });
  assert.ok(await editLink.isVisible(), "the start page links to the notebook this server was started with");

  const text = await page.locator("body").innerText();
  assert.match(text, /ember/i);
  assert.doesNotMatch(text, /welcome to pluto/i);
});

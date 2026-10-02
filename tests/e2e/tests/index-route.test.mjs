// review4 item 10: "/" used to serve Pluto's vendored Julia welcome page
// (frontend/index.html, served automatically by httpuv's static handler for
// the bare "/" path) instead of Ember's own list of hosted notebooks.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage } from "../browser.mjs";

test('index: "/" shows Ember\'s own hosted-notebook list, not Pluto\'s Julia welcome page', async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "index-route.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  const resp = await page.goto(`${server.url}`);
  assert.equal(resp.status(), 200);

  const text = await page.locator("body").innerText();
  assert.match(text, /ember/i);
  assert.doesNotMatch(text, /welcome to pluto/i);

  // Ember's own page links to edit?id= (relative, not "/edit?...": a proxy
  // serving Ember under a path prefix strips the prefix before forwarding,
  // so an absolute link would point the browser at the wrong, unprefixed
  // path; see R/server.R's http_index()) for every hosted notebook.
  const editLinks = await page.locator('a[href*="edit?id="]').count();
  assert.ok(editLinks >= 1, "the index links to at least the one notebook this server was started with");
});

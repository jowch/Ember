// Remote use (docs/design-gaps.md): a reverse proxy puts Ember on a
// different port than the one it's actually listening on, and under a path
// prefix it knows nothing about (Posit Workbench, JupyterHub's server
// proxy, VS Code port forwarding all work this way). Two bugs made that
// combination fail: the Host/Origin check only accepted the server's own
// 127.0.0.1:<port> (so the proxy's port alone got 403), and every URL Ember
// built (the `/open` redirect, the `/` index's links) was absolute, so a
// browser that followed one lost the prefix. This drives a real notebook
// entirely through proxy.mjs's reverse proxy -- the only thing Playwright
// ever talks to -- and checks the page loads and a cell runs.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { startReverseProxy } from "../proxy.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

test("reverse proxy: a notebook opens and a cell runs through a path prefix on a different port", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "reverse-proxy.server.log") });
  const emberPort = Number(new URL(server.url).port);

  // A prefix unrelated to Ember's own port or routes, the way a hub mounts
  // one user's service under an opaque path.
  const prefix = "/s/abc123/p/1";
  const proxy = await startReverseProxy(emberPort, prefix);
  assert.notEqual(proxy.port, emberPort, "the proxy listens on its own port, not Ember's");
  const proxiedOrigin = `http://127.0.0.1:${proxy.port}${prefix}/`;

  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); proxy.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, proxiedOrigin, server.secret, notebook);

  // The redirect from /open and the page's own links are relative, so the
  // browser should have landed on an /edit URL that still carries the
  // proxy's prefix -- if it didn't, this URL would have come from Ember's
  // absolute "/edit?..." instead, which the proxy would have 404'd before
  // openNotebook() ever saw a loaded editor.
  assert.ok(page.url().startsWith(proxiedOrigin + "edit"), "stayed under the proxy's prefix: " + page.url());

  const cellCount = await page.locator("pluto-cell").count();
  assert.equal(cellCount, 6, "setup + 5 cells from the fixture, loaded entirely through the proxy");

  await runCell(page, "B");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  assertNoProblems(page);
});

test("reverse proxy: the bare prefix (no trailing slash) resolves its relative links one level too high (design-gaps.md)", async (t) => {
  // Not fixable in Ember itself: proxy.mjs's forwardPath() collapses both
  // the bare prefix and the prefix with a trailing slash to exactly "/"
  // once forwarded, so this process can't tell which one the browser
  // actually requested (it never learns the prefix at all). This test
  // demonstrates the gap docs/design-gaps.md records, rather than a bug in
  // Ember's own output: http_open()'s "Location: edit?id=..." (also what
  // the start page's ember_new_notebook/ember_open_notebook replies carry)
  // is correct relative to a trailing-slash URL, and wrong relative to a
  // bare one -- that is simply what a relative link does.
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "reverse-proxy-bare.server.log") });
  const emberPort = Number(new URL(server.url).port);
  const prefix = "/s/def456/p/1";
  const proxy = await startReverseProxy(emberPort, prefix);
  t.after(() => { server.stop(); proxy.stop(); });

  // The real relative URL Ember hands back for a notebook (the same
  // string the start page's ember_new_notebook/ember_open_notebook
  // replies carry, and what /open redirects to): "edit?id=...&secret=...".
  const qs = `path=${encodeURIComponent(notebook)}&secret=${server.secret}`;
  const res = await fetch(`http://127.0.0.1:${proxy.port}${prefix}/open?${qs}`, { redirect: "manual" });
  const location = res.headers.get("location");
  assert.match(location ?? "", /^edit\?id=/, "the /open redirect is a relative edit link");

  // What the browser would actually do if it used that same relative
  // string from the bare-prefix start page (no trailing slash): resolve
  // it against the page it's really at, landing one path segment too
  // high -- at ".../p/edit?..." instead of ".../p/1/edit?...".
  const resolved = new URL(location, `http://127.0.0.1:${proxy.port}${prefix}`);
  assert.equal(resolved.pathname, "/s/def456/p/edit", "resolves one level too high, as the doc note says");
  assert.notEqual(resolved.pathname, `${prefix}/edit`);
});

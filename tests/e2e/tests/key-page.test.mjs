// A page asked for without Ember's key (the secret), or with the key from
// an earlier session, gets a page that says what happened and what to do,
// not a bare "403" line. An editor tab left open across a restart says the
// same in its header and a dialog, instead of reconnecting forever.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import http from "node:http";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, openNotebook, assertNoProblems } from "../browser.mjs";

test("key page: '/' without the key explains it in light and dark, and echoes nothing", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "key-page.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  for (const scheme of ["light", "dark"]) {
    const page = await newPage(browser);
    await page.emulateMedia({ colorScheme: scheme });
    const failed = [];
    page.on("response", (r) => { if (r.status() >= 400 && r.request().resourceType() !== "document") failed.push(r.url()); });
    const resp = await page.goto(`${server.origin}edit?id=some-old-id&secret=an-old-secret`);
    assert.equal(resp.status(), 403);
    assert.match(resp.headers()["content-type"], /^text\/html/);

    await page.getByRole("heading", { name: "This link needs Ember's current key" }).waitFor();
    const text = await page.locator("body").innerText();
    assert.match(text, /Ember makes a new key each time it starts/);
    assert.match(text, /open the link Ember just printed in the R console/);
    assert.match(text, /ember::start_server\(\)/);

    const html = await page.content();
    for (const leak of ["an-old-secret", "some-old-id", server.secret]) {
      assert.ok(!html.includes(leak), `the page doesn't contain ${leak}`);
    }

    const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    assert.equal(bg, scheme === "light" ? "rgb(245, 246, 243)" : "rgb(21, 25, 23)");
    await page.screenshot({ path: path.join(artifactsDir(), `key-page-${scheme}.png`) });
    // Chromium logs the page's own 403 as a console error; anything else
    // (a font or stylesheet the page failed to load) is a real problem.
    page.problems.splice(0, page.problems.length,
      ...page.problems.filter((p) => !/status of 403/.test(p)));
    assert.equal(failed.length, 0, `the page's own files load: ${failed.join(", ")}`);
    assertNoProblems(page);
    await page.context().close();
  }

  const page = await newPage(browser);
  const resp = await page.goto(server.origin);
  assert.equal(resp.status(), 403);
  await page.getByRole("heading", { name: "This link needs Ember's current key" }).waitFor();
  await page.context().close();

  // The server prints the working link for whoever started it.
  assert.match(server.log(), new RegExp(`A browser asked for Ember without its key\\. Open: ${server.url.replace(/[.?]/g, "\\$&")}`));
});

test("key page: an editor tab open across a restart says Ember restarted and stops reconnecting", async (t) => {
  const notebook = tempNotebook();
  const logFile = path.join(artifactsDir(), "key-page-restart.server.log");
  const first = await startServer([notebook], { logFile, secret: "first-session-secret" });
  let second = null;
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); first.stop(); second?.stop(); });

  const page = await newPage(browser);
  let sockets = 0;
  page.on("websocket", () => { sockets += 1; });
  await openNotebook(page, first.origin, first.secret, notebook);

  await first.stop();
  second = await startServer([notebook], { logFile, port: first.port, secret: "second-session-secret" });

  const dialog = page.getByRole("alertdialog");
  await dialog.waitFor({ timeout: 30000 });
  assert.match(await dialog.innerText(), /Ember restarted, so this page's key no longer works\. Open the link Ember just printed in the R console/);
  assert.match(await page.locator("#ember-r-status").innerText(), /Ember restarted/);
  await page.screenshot({ path: path.join(artifactsDir(), "key-page-restarted-tab.png") });

  const after_refusal = sockets;
  await page.waitForTimeout(3000);
  assert.equal(sockets, after_refusal, "no further reconnect attempts once the key was refused");
});

// The race the test above can hit: a socket that drops while the old
// server is gone fails with 1006, and the page's key check then reaches a
// server that refuses the old key. Here a stand-in holds the port in
// exactly that state: every request gets 403, every websocket upgrade is
// dropped. The page must still say Ember restarted, in the dialog and the
// header, and stop retrying -- not show "lost its connection" and keep
// opening sockets every few seconds.
test("key page: a refused key check while the socket can't connect says Ember restarted and stops retrying", async (t) => {
  const notebook = tempNotebook();
  const logFile = path.join(artifactsDir(), "key-page-check-refused.server.log");
  const first = await startServer([notebook], { logFile, secret: "first-session-secret" });
  let standIn = null;
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); first.stop(); standIn?.close(); });

  const page = await newPage(browser);
  let sockets = 0;
  page.on("websocket", () => { sockets += 1; });
  await openNotebook(page, first.origin, first.secret, notebook);

  await first.stop();
  standIn = http.createServer((req, res) => { res.writeHead(403); res.end(); });
  standIn.on("upgrade", (req, socket) => socket.destroy());
  await new Promise((resolve) => standIn.listen(first.port, "127.0.0.1", resolve));

  const dialog = page.getByRole("alertdialog");
  await dialog.waitFor({ timeout: 30000 });
  assert.match(await dialog.innerText(), /Ember restarted, so this page's key no longer works/);
  await page.locator("#ember-r-status", { hasText: "Ember restarted" }).waitFor({ timeout: 30000 });

  // Longer than the page's retry delay after a failed connect (5 s).
  const after_refusal = sockets;
  await page.waitForTimeout(7000);
  assert.equal(sockets, after_refusal, "no further reconnect attempts once the key check was refused");
  assert.equal(await page.getByRole("alertdialog").count(), 1, "one dialog, not a lost-connection one as well");
});

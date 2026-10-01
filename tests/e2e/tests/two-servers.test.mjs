// review4 item 5: two Ember servers on 127.0.0.1 used to share one cookie
// name ("ember_secret"), and cookies ignore port (RFC 6265) -- so opening a
// second server in the same browser profile overwrote the first server's
// cookie, breaking its "Save notebook" (/notebookfile) and "Export"
// (/notebookexport) links, which rely on the cookie alone (no `secret=` in
// those URLs). The fix names the cookie per port.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, openNotebook } from "../browser.mjs";

test("two-servers: opening a second server doesn't break the first's notebookfile/notebookexport links", async (t) => {
  const notebookA = tempNotebook();
  const notebookB = tempNotebook();
  const serverA = await startServer([notebookA], { logFile: path.join(artifactsDir(), "two-servers-a.server.log") });
  const serverB = await startServer([notebookB], { logFile: path.join(artifactsDir(), "two-servers-b.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); serverA.stop(); serverB.stop(); });

  const ctx = await browser.newContext();
  const a = await ctx.newPage();
  const idA = await openNotebook(a, serverA.origin, serverA.secret, notebookA);

  const before = await a.evaluate(
    (id) => fetch(`./notebookfile?id=${id}`).then((r) => r.status),
    idA);
  assert.equal(before, 200, "server A's notebookfile link works before server B is opened");

  const b = await ctx.newPage();
  await openNotebook(b, serverB.origin, serverB.secret, notebookB); // same browser profile/cookie jar

  const cookies = await ctx.cookies();
  const names = cookies.filter((c) => c.name.startsWith("ember_secret")).map((c) => c.name);
  assert.equal(new Set(names).size, names.length, "each server's cookie has its own name, so neither overwrote the other");

  const after = await a.evaluate(
    (id) => fetch(`./notebookfile?id=${id}`).then((r) => r.status),
    idA);
  const afterExport = await a.evaluate(
    (id) => fetch(`./notebookexport?id=${id}`).then((r) => r.status),
    idA);
  assert.equal(after, 200, "server A's notebookfile link still works after server B is opened");
  assert.equal(afterExport, 200, "server A's notebookexport link still works after server B is opened");
});

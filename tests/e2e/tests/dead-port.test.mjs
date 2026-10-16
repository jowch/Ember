// A tab whose address nothing answers any more (Ember stopped, or started
// again on another port, or the tunnel to it closed) stops saying
// "Reconnecting" and says Ember isn't running there, with Try again (#33).
// It keeps trying in the background, so it reconnects by itself if Ember
// comes back at the same address.
//
// The page reaches Ember through a plain TCP forwarder on a port of its own:
// stopping the forwarder leaves the page's port dead, and starting it again
// on the same port brings back the same server, the same key and the same
// notebook, the way an SSH tunnel that dropped and came back would.
//
// The page's waits (30 s of failures before it says so, 10 s between
// background tries) run on Playwright's fake clock, moved forward by hand,
// so nothing here depends on how long those waits really are.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import net from "node:net";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, openNotebook } from "../browser.mjs";

/** No uncaught error on the page. Failed connects log console errors of
 * their own (the browser's and the page's), which are expected here. */
function assertNoPageErrors(page) {
  const errors = page.problems.filter((p) => p.startsWith("pageerror:") || p.startsWith("dialog:"));
  assert.deepEqual(errors, []);
}

/** Forward 127.0.0.1:`port` (0 for any free port) to `targetPort`. Resolves
 * to `{ port, stop() }`; `stop()` drops every open connection too. */
function startForwarder(targetPort, port = 0) {
  const open = new Set();
  const server = net.createServer((client) => {
    const upstream = net.connect(targetPort, "127.0.0.1");
    const drop = () => { client.destroy(); upstream.destroy(); open.delete(client); open.delete(upstream); };
    open.add(client); open.add(upstream);
    client.on("error", drop); upstream.on("error", drop);
    client.on("close", drop); upstream.on("close", drop);
    client.pipe(upstream); upstream.pipe(client);
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => resolve({
      port: server.address().port,
      stop: () => new Promise((done) => { for (const s of open) s.destroy(); server.close(() => done()); }),
    }));
  });
}

/** Move the page's fake clock forward a step at a time until `locator`
 * shows up: the page's own waits fire, the tries they start run for real. */
async function fastForwardUntil(page, locator, { step = 5000, limit = 120000 } = {}) {
  for (let moved = 0; moved <= limit; moved += step) {
    if (await locator.count() > 0) return;
    await page.clock.fastForward(step);
    try { await locator.waitFor({ timeout: 1000 }); return; } catch {}
  }
  throw new Error(`still no ${locator} after moving the clock ${limit} ms`);
}

/** Open the notebook through a forwarder, then take the forwarder away. */
async function openThenKillPort(t, name) {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), `${name}.server.log`) });
  let forwarder = await startForwarder(server.port);
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); await forwarder.stop(); server.stop(); });

  const page = await newPage(browser);
  await page.clock.install();
  const origin = `http://127.0.0.1:${forwarder.port}/`;
  await openNotebook(page, origin, server.secret, notebook);
  const status = page.locator("#ember-r-status");
  await status.filter({ hasText: "R not started" }).waitFor({ timeout: 30000 });

  const port = forwarder.port;
  await forwarder.stop();
  await status.filter({ hasText: "Reconnecting" }).waitFor({ timeout: 30000 });

  const bringBack = async () => { forwarder = await startForwarder(server.port, port); };
  return { page, status, bringBack, port, notebook };
}

test("dead port: the tab says Ember isn't running here, and Try again reconnects once it's back", async (t) => {
  const { page, status, bringBack, port } = await openThenKillPort(t, "dead-port-try-again");

  const dialog = page.getByRole("alertdialog", { name: "Ember isn't running here" });
  await fastForwardUntil(page, dialog);
  assert.match(await dialog.innerText(), new RegExp(`Nothing at 127\\.0\\.0\\.1:${port} answers as Ember`));
  assert.match(await dialog.innerText(), /ember::start_server\(\)/);
  assert.match(await status.innerText(), /Ember not running/);

  // The Status tab says the same as the header.
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "process" })));
  assert.match(await page.locator("#ember-status-tab .ember-status-state").innerText(), /Ember not running/);
  await page.screenshot({ path: path.join(artifactsDir(), "dead-port-not-running.png") });

  // Try again while the port is still dead: the page tries at once and
  // says so again (a second dialog, asked after the click), without the
  // clock moving.
  const asked = () => page.evaluate(() => window.ember_dialogs.filter((d) => d.title === "Ember isn't running here").length);
  assert.equal(await asked(), 1);
  await dialog.getByRole("button", { name: "Try again" }).click();
  await page.waitForFunction(() => window.ember_dialogs.filter((d) => d.title === "Ember isn't running here").length === 2, null, { timeout: 30000 });
  await dialog.waitFor({ timeout: 30000 });

  // Try again once something answers there: the page reconnects at once,
  // without waiting for its next background try.
  await bringBack();
  await dialog.getByRole("button", { name: "Try again" }).click();
  await status.filter({ hasText: "R not started" }).waitFor({ timeout: 30000 });
  assert.equal(await page.getByRole("alertdialog").count(), 0, "no dialog left once it's back");
  assertNoPageErrors(page);
});

test("dead port: a tab that said Ember isn't running reconnects by itself when it comes back", async (t) => {
  const { page, status, bringBack } = await openThenKillPort(t, "dead-port-background");

  const dialog = page.getByRole("alertdialog", { name: "Ember isn't running here" });
  await fastForwardUntil(page, dialog);
  // Left open on purpose: coming back takes it away.

  await bringBack();
  await fastForwardUntil(page, status.filter({ hasText: "R not started" }));
  await dialog.waitFor({ state: "detached", timeout: 30000 });
  assertNoPageErrors(page);
});

test("dead port: a tab that said Ember isn't running says Ember restarted when a new one starts at its address", async (t) => {
  const { page, status, port, notebook } = await openThenKillPort(t, "dead-port-restarted");

  const dialog = page.getByRole("alertdialog", { name: "Ember isn't running here" });
  await fastForwardUntil(page, dialog);

  const second = await startServer([notebook], {
    logFile: path.join(artifactsDir(), "dead-port-restarted.second.server.log"), port, secret: "second-session-secret",
  });
  t.after(() => second.stop());
  const restarted = page.getByRole("alertdialog", { name: "Ember restarted" });
  await fastForwardUntil(page, restarted);
  await status.filter({ hasText: "Ember restarted" }).waitFor({ timeout: 30000 });
  assert.equal(await dialog.count(), 0, "the not-running dialog went when the restart was found");
  assertNoPageErrors(page);
});

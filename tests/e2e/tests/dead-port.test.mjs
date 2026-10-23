// A tab whose address nothing answers any more (Ember stopped, or started
// again on another port, or the tunnel to it closed) stops saying
// "Reconnecting" and says it can't reach Ember there, with Try again (#33).
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
import http from "node:http";
import crypto from "node:crypto";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, openNotebook, connectionSettled } from "../browser.mjs";

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
 * shows up: the page's own waits fire, the tries they start run for real,
 * and each step waits for them to end. */
async function fastForwardUntil(page, locator, { step = 5000, limit = 120000 } = {}) {
  for (let moved = 0; moved <= limit; moved += step) {
    if (await locator.count() > 0) return;
    await page.clock.fastForward(step);
    await connectionSettled(page);
  }
  if (await locator.count() > 0) return;
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

test("dead port: the tab says it can't reach Ember, and Try again reconnects once it's back", async (t) => {
  const { page, status, bringBack, port } = await openThenKillPort(t, "dead-port-try-again");

  const dialog = page.getByRole("alertdialog", { name: "Can't reach Ember here" });
  await fastForwardUntil(page, dialog);
  assert.match(await dialog.innerText(), new RegExp(`Nothing at 127\\.0\\.0\\.1:${port} answers as Ember`));
  assert.match(await dialog.innerText(), /ember::start_server\(\)/);
  assert.match(await status.innerText(), /Can't reach Ember/);

  // The Status tab says the same as the header.
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "process" })));
  assert.match(await page.locator("#ember-status-tab .ember-status-state").innerText(), /Can't reach Ember/);
  await page.screenshot({ path: path.join(artifactsDir(), "dead-port-not-running.png") });

  // Try again while the port is still dead: the page tries at once and
  // says so again (a second dialog, asked after the click), without the
  // clock moving.
  const asked = () => page.evaluate(() => window.ember_dialogs.filter((d) => d.title === "Can't reach Ember here").length);
  assert.equal(await asked(), 1);
  await dialog.getByRole("button", { name: "Try again" }).click();
  await page.waitForFunction(() => window.ember_dialogs.filter((d) => d.title === "Can't reach Ember here").length === 2, null, { timeout: 30000 });
  await dialog.waitFor({ timeout: 30000 });

  // Try again once something answers there: the page reconnects at once,
  // without waiting for its next background try.
  await bringBack();
  await dialog.getByRole("button", { name: "Try again" }).click();
  await status.filter({ hasText: "R not started" }).waitFor({ timeout: 30000 });
  assert.equal(await page.getByRole("alertdialog").count(), 0, "no dialog left once it's back");
  assertNoPageErrors(page);
});

test("dead port: a tab that said it can't reach Ember reconnects by itself when it comes back", async (t) => {
  const { page, status, bringBack } = await openThenKillPort(t, "dead-port-background");

  const dialog = page.getByRole("alertdialog", { name: "Can't reach Ember here" });
  await fastForwardUntil(page, dialog);
  // Left open on purpose: coming back takes it away.

  await bringBack();
  await fastForwardUntil(page, status.filter({ hasText: "R not started" }));
  await dialog.waitFor({ state: "detached", timeout: 30000 });
  assertNoPageErrors(page);
});

test("dead port: a tab that said it can't reach Ember says Ember restarted when a new one starts at its address", async (t) => {
  const { page, status, port, notebook } = await openThenKillPort(t, "dead-port-restarted");

  const dialog = page.getByRole("alertdialog", { name: "Can't reach Ember here" });
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

// The regression this change risks: a short outage, well under the 30 s,
// must reconnect as before, with no dialog at all.
test("dead port: an outage shorter than 30 s reconnects without a dialog", async (t) => {
  const { page, status, bringBack } = await openThenKillPort(t, "dead-port-short");

  for (let moved = 0; moved < 25000; moved += 5000) {
    await page.clock.fastForward(5000);
    await connectionSettled(page);
  }
  await bringBack();
  await fastForwardUntil(page, status.filter({ hasText: "R not started" }), { step: 1000, limit: 10000 });
  assert.deepEqual(await page.evaluate(() => window.ember_dialogs.map((d) => d.title)), []);
  assertNoPageErrors(page);
});

// A computer that sleeps mid-outage: the wall clock jumps by the length of
// the sleep, but the page's own timers don't run (#99). On wake the next
// try fails because the network isn't up yet, and that alone must not be
// "30 s of failures". setSystemTime moves Date.now() without firing timers.
test("dead port: a sleep in the middle of an outage doesn't count towards the 30 s (#99)", async (t) => {
  const { page } = await openThenKillPort(t, "dead-port-sleep");
  const dialog = page.getByRole("alertdialog", { name: "Can't reach Ember here" });

  // One failed try, then an hour's sleep. The clock stays paused from here
  // on, so only fastForward moves it, however slow the runner is.
  await page.clock.pauseAt(await page.evaluate(() => Date.now() + 1000));
  await connectionSettled(page);
  await page.clock.setSystemTime(await page.evaluate(() => Date.now() + 60 * 60 * 1000));

  // Tries after waking, about 20 s of the page's own waits: still no dialog.
  for (let moved = 0; moved < 20000; moved += 1000) {
    await page.clock.fastForward(1000);
    await connectionSettled(page);
  }
  assert.deepEqual(await page.evaluate(() => window.ember_dialogs.map((d) => d.title)), []);

  // It still says so once the outage has lasted 30 s on its own clock.
  await fastForwardUntil(page, dialog);
  assertNoPageErrors(page);
});

// Something at the address that accepts the websocket and closes it before
// Ember's "connect" reply (Ember itself does this for a page from another
// origin) is a failed try too: the page says it can't reach Ember, instead
// of reconnecting every half second for ever.
test("dead port: a socket that opens and closes before Ember answers counts as a failed try", async (t) => {
  const { page, port } = await openThenKillPort(t, "dead-port-open-close");

  let upgrades = 0;
  const standIn = http.createServer((req, res) => { res.writeHead(404); res.end(); });
  standIn.on("upgrade", (req, socket) => {
    upgrades += 1;
    const accept = crypto.createHash("sha1")
      .update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.end(Buffer.from([0x88, 0x02, 0x03, 0xe8])); // close frame, code 1000
  });
  await new Promise((resolve) => standIn.listen(port, "127.0.0.1", resolve));
  t.after(() => standIn.close());

  const dialog = page.getByRole("alertdialog", { name: "Can't reach Ember here" });
  await fastForwardUntil(page, dialog);
  assert.ok(upgrades > 0, "the page did reach the stand-in");
  assert.match(await page.locator("#ember-r-status").innerText(), /Can't reach Ember/);
  assertNoPageErrors(page);
});

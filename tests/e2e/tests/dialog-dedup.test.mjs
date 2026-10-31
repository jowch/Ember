// A regression test for the fix to PlutoConnection.js's connect() loop:
// every 401/403 called tell() for lost authentication, and every retry
// (every 5s, forever) queued another identical dialog. ask()/tell()/
// reload_prompt() now take a `key`; a second call with a key already
// queued or showing is dropped and returns the first call's promise
// instead of opening a second dialog. This drives common/dialogs.js
// directly (dynamic import of the module the app itself already loaded),
// since reproducing real repeated auth failures end to end would need a
// much heavier setup for the same unit of behavior.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

test("dialogs.js: a second ask()/tell() with the same key is dropped, not queued", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "dialog-dedup.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const result = await page.evaluate(async () => {
    const mod = await import("./common/dialogs.js");
    const p1 = mod.tell({ body: "first", key: "dup-test" });
    const p2 = mod.tell({ body: "second", key: "dup-test" });
    const open_count = document.querySelectorAll("dialog.ember-dialog[open]").length;
    const shown_text = document.querySelector("dialog.ember-dialog[open] .ember-dialog-text")?.textContent;
    document.querySelector("dialog.ember-dialog[open] button.primary").click();
    const [r1, r2] = await Promise.all([p1, p2]);
    return { open_count, shown_text, same_resolution: r1 === r2 };
  });

  assert.equal(result.open_count, 1, "only one dialog opened for two calls with the same key");
  assert.equal(result.shown_text, "first", "the first call's dialog is the one shown");
  assert.ok(result.same_resolution, "both calls resolve together");

  assertNoProblems(page);
});

test("dialogs.js: a dismissed dialog leaves the queue without its close event, so the next one shows (#491)", async (t) => {
  // On a macOS runner, dismiss() closed "Can't reach Ember here" and no
  // close event followed, so "Ember restarted" stayed queued behind it.
  // The stub closes the element as close() does, without the event.
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "dialog-no-close-event.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const result = await page.evaluate(async () => {
    const mod = await import("./common/dialogs.js");
    const real_close = HTMLDialogElement.prototype.close;
    HTMLDialogElement.prototype.close = function () { this.removeAttribute("open"); };
    const shown = () => document.querySelector("dialog.ember-dialog[open] .ember-dialog-text")?.textContent ?? null;
    const settle = () => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
    try {
      const out = {};
      // dismiss(), as tell_key_refused() uses it.
      mod.tell({ body: "unreachable", key: "no-close-a" });
      await settle();
      out.first = shown();
      mod.dismiss("no-close-a");
      mod.tell({ body: "restarted", key: "no-close-b" });
      await settle();
      out.after_dismiss = shown();
      document.querySelector("dialog.ember-dialog[open] button.primary")?.click();
      await settle();
      out.left_open = document.querySelectorAll("dialog.ember-dialog[open]").length;
      out.queue = window.ember_dialog_queue.length;
      return out;
    } finally {
      HTMLDialogElement.prototype.close = real_close;
    }
  });

  assert.equal(result.first, "unreachable", "the first dialog showed before it was dismissed");
  assert.equal(result.after_dismiss, "restarted", "the dialog queued behind a dismissed one shows");
  assert.equal(result.left_open, 0, "no dialog is left open");
  assert.equal(result.queue, 0, "the queue is empty");

  assertNoProblems(page);
});

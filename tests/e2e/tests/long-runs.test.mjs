// Ask before long runs, test 169 of docs/ui-3-tests.md: the dialog says
// what will rerun and waits for an answer.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, runCell } from "../browser.mjs";

test("long runs: the dialog names the rerun, never answers itself, and Cancel runs nothing (169)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "long-runs-169.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.addInitScript(() => localStorage.setItem("pluto_setting_CONFIRM_LONG_RUNTIMES_SECONDS", "1"));
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "LOOP");
  await page.waitForFunction(() => {
    const r = window.editor_state?.notebook?.cell_results?.LOOP;
    return r != null && !r.running && !r.queued && r.runtime > 1e9;
  }, null, { timeout: 60000 });
  const ran_at = await page.evaluate(() => window.editor_state.notebook.cell_results.LOOP.output.last_run_timestamp);

  await page.locator(`${cellSelector("LOOP")} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.keyboard.press("End");
  await page.keyboard.type(" ");
  await page.keyboard.press("Shift+Enter");

  const dialog = page.locator("dialog.confirm-before-long-runtime[open]");
  await dialog.waitFor({ timeout: 5000 });
  assert.equal((await dialog.locator("p").innerText()).trim(), "This reruns 1 cell that took about 8 sec last time.");

  // The finished-run notification (RunTracker.js) words its time the same way, as board Words6 does.
  const notification = await page.evaluate(async () => {
    const src = document.querySelector('script[src$="editor.js"]').src;
    const { t, pretty_long_time } = await import(new URL("common/lang.js", src).href);
    return [t("t_run_notif_title", { file: "analysis.R" }), t("t_run_notif_body", { count: 5, time: pretty_long_time(185) })];
  });
  assert.deepEqual(notification, ["analysis.R finished", "5 cells ran in 3 min"]);

  await page.waitForTimeout(25000);
  assert.equal(await dialog.count(), 1, "still open after 25 s");

  await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
  await dialog.waitFor({ state: "detached", timeout: 5000 });
  await page.waitForTimeout(1000);
  const after = await page.evaluate(() => {
    const r = window.editor_state.notebook.cell_results.LOOP;
    return { running: r.running, queued: r.queued, ran_at: r.output.last_run_timestamp };
  });
  assert.deepEqual(after, { running: false, queued: false, ran_at });

  // Put the code back, so leaving the page doesn't ask about edits.
  await page.locator(`${cellSelector("LOOP")} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.keyboard.press("End");
  await page.keyboard.press("Backspace");
  assertNoProblems(page);
});

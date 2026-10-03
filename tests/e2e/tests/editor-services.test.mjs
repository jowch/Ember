// Piece 4 (docs/ui-2.md, "Editor services"), scenarios 59-61 of
// docs/ui-2-tests.md: completion, the help panel and the signature
// tooltip against a real server and worker. Scenario 62 (go-to-definition)
// is cut from this increment (ui-2.md, 4e) and has no test here.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

/** Type `code` into the cell at `sel`, open the completion popup and check
 * `predicate(labels)`, retrying (clear, retype) for up to `timeout`ms. A
 * CI runner busy with other e2e suites can be slow enough that the first
 * keystroke's request answers after the worker reaches "ready" but the
 * popup still shows an earlier, now-stale result; retyping forces a fresh
 * request rather than waiting out a race that already happened. */
async function completion_eventually(page, sel, code, predicate, timeout = 30000) {
  await page.waitForSelector(sel, { timeout });
  const locator = page.locator(`${sel} .cm-content`);
  const deadline = Date.now() + timeout;
  let labels = [];
  while (Date.now() < deadline) {
    // Re-focus every attempt: closing the popup with Escape can also blur
    // the cell, and typing into nothing would retry forever on the same
    // stale (never actually retyped) text.
    await locator.click({ timeout });
    await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
    await page.keyboard.press("Backspace");
    await page.keyboard.type(code, { delay: 10 });
    try {
      await page.waitForSelector(".cm-tooltip-autocomplete .cm-completionLabel", { timeout: 3000 });
      labels = await page.locator(".cm-tooltip-autocomplete .cm-completionLabel").allInnerTexts();
      if (predicate(labels)) return labels;
    } catch {
      // no popup yet within this attempt's window; retry.
    }
    await page.keyboard.press("Escape");
  }
  throw new Error(`completion for ${JSON.stringify(code)} never satisfied the predicate; last labels: ${JSON.stringify(labels)}`);
}

/** Click the completion option whose label is exactly `label` (open popup
 * assumed) and wait for the popup to close, then return the cell's text.
 * Finding 2 (a worker completion after `$`/`@`/a quoted path duplicating
 * the receiver, e.g. "df$df$mpg") and finding 1 (a multi-line cell's
 * replace range landing on the wrong line) both only show up once a
 * completion is actually accepted, not just listed. Never leaves the cell
 * empty between steps (deliberately, like completion_eventually() above):
 * an empty cell that loses focus gets removed. */
async function accept_completion(page, sel, label) {
  const option = page.locator(".cm-tooltip-autocomplete .cm-completionLabel").filter({ hasText: new RegExp(`^${label}$`) }).first();
  await option.click();
  await page.waitForFunction(
    () => document.querySelector(".cm-tooltip-autocomplete") == null,
    null, { timeout: 5000 }
  ).catch(() => {}); // the popup may already be gone by the time this runs
  return await page.locator(`${sel} .cm-content`).innerText();
}

test("completion: typing me then Ctrl+Space lists mean; after running DF, df$ lists mpg (59)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-complete.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("DF"));
  await page.locator(`${cellSelector("DF")} button.add_cell.after`).click({ force: true });
  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "DF");
  assert.ok(newCellId, "a new cell was inserted right after DF");
  const newSel = `pluto-cell[id="${newCellId}"]`;

  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("me", { delay: 10 });
  await page.keyboard.press("Control+Space");
  await page.waitForSelector(".cm-tooltip-autocomplete .cm-completionLabel", { timeout: 10000 });
  const labels = await page.locator(".cm-tooltip-autocomplete .cm-completionLabel").allInnerTexts();
  assert.ok(labels.includes("mean"), `expected "mean" among ${JSON.stringify(labels)}`);

  await page.screenshot({ path: path.join(artifactsDir(), "completion-base.png") });

  await page.keyboard.press("Escape");
  // Not cleared to empty here: a brand-new cell that's empty when focus
  // leaves it gets removed (found by watching the cell vanish right after
  // runCell(DF) below, long before anything types into it again).
  // completion_eventually() below replaces "me" the same way it replaces
  // any other stale text.

  await runCell(page, "DF");
  // Not just "DF finished running": the worker only answers completion
  // itself once it's back to "ready" (ui-2.md, 4a) -- right after
  // submitting DF (the notebook's first run) it's briefly "starting" while
  // the worker process comes up, when completion still falls back.
  await page.waitForFunction(() => {
    const nb = window.editor_state?.notebook;
    const r = nb?.cell_results?.DF;
    return nb?.process_status === "ready" && r && !r.running && !r.queued &&
      (r.output?.last_run_timestamp ?? 0) > 0;
  }, null, { timeout: 60000 });

  await completion_eventually(page, newSel, "df$", (ls) => ls.includes("mpg"), 60000);
  await page.screenshot({ path: path.join(artifactsDir(), "completion-notebook-var.png") });
  // Accepting "mpg" must replace only the part after "$": the worker's own
  // completion token/items for a `$` completion include the receiver
  // ("df$mpg"), which would duplicate it onto "df$" if the reply's
  // start/stop didn't already account for that (finding 2).
  const after_field_completion = await accept_completion(page, newSel, "mpg");
  assert.equal(after_field_completion, "df$mpg");

  // completion_eventually() does its own clear-and-retype (never leaving
  // the cell empty and unfocused, which would get it removed).
  const stats_labels = await completion_eventually(page, newSel, "stats::", (ls) => ls.length > 0);
  assert.ok(stats_labels.length > 0, "stats:: offered some completions");
  await page.screenshot({ path: path.join(artifactsDir(), "completion-stats-namespace.png") });
  await page.keyboard.press("Escape");

  // A multi-line cell: completion_context()'s start/stop must be an
  // offset into the *whole* cell text, not just the last line, or
  // accepting here would land on the wrong line (finding 1).
  // `keyboard.type()` presses Enter for an embedded "\n", same as typing
  // the second line by hand.
  await completion_eventually(page, newSel, "x <- 1\nme", (ls) => ls.includes("mean"), 30000);
  const after_multiline_completion = await accept_completion(page, newSel, "mean");
  assert.equal(after_multiline_completion, "x <- 1\nmean");

  assertNoProblems(page);
});

test("completion still works on the notebook's names and base R while a cell runs (59)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-complete-busy.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator(`${cellSelector("LOOP")} .cm-content`).click();
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction(
    () => document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running"),
    null, { timeout: 10000 });

  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.add_cell.after`).click({ force: true });
  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "B");
  const newSel = `pluto-cell[id="${newCellId}"]`;

  const start = Date.now();
  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("su", { delay: 10 });
  await page.waitForSelector(".cm-tooltip-autocomplete .cm-completionLabel", { timeout: 1000 });
  const labels = await page.locator(".cm-tooltip-autocomplete .cm-completionLabel").allInnerTexts();
  assert.ok(labels.includes("sum"), `expected "sum" among ${JSON.stringify(labels)}`);
  assert.ok(Date.now() - start < 1000, "the fallback answered within 1s while the worker was busy");

  assertNoProblems(page);
});

test("help: the cursor inside mean( shows Arithmetic Mean; a link loads another page; examples highlight as R (60)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-help.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "DF");
  // See the completion test above: the worker answers "mean"'s help only
  // once it's back to "ready", not merely once DF has run.
  await page.waitForFunction(
    () => window.editor_state?.notebook?.process_status === "ready",
    null, { timeout: 30000 });

  await page.hover(cellSelector("DF"));
  await page.locator(`${cellSelector("DF")} button.add_cell.after`).click({ force: true });
  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "DF");
  const newSel = `pluto-cell[id="${newCellId}"]`;

  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("mean(df$mpg", { delay: 10 });
  await page.keyboard.press("Escape"); // close any autocomplete popup first

  await page.locator("button.helpbox-docs").click();
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("Arithmetic Mean"),
    null, { timeout: 15000 });

  await page.screenshot({ path: path.join(artifactsDir(), "help-panel-light.png") });
  await page.emulateMedia({ colorScheme: "dark" });
  await page.screenshot({ path: path.join(artifactsDir(), "help-panel-dark.png") });
  await page.emulateMedia({ colorScheme: "light" });

  // "mean"'s Examples section (Rd2HTML's `<pre><code class="language-R">`)
  // must come back highlighted as R, not as plain text: RawHTMLContainer's
  // highlighting pass (CellOutput.js) turns that into hljs's own markup.
  const examples_code = page.locator("#helpbox-wrapper pre code").first();
  await examples_code.waitFor({ timeout: 15000 });
  const examples_class = await examples_code.getAttribute("class");
  assert.match(examples_class ?? "", /\bhljs\b/, "the examples code block was passed to hljs");
  const highlighted_tokens = await examples_code.locator('[class*="hljs-"]').count();
  assert.ok(highlighted_tokens > 0, "the examples code got at least one hljs-* token span");

  // "See Also" names other topics as `@ref` links (rewrite_help_links());
  // mean's page always has some (weighted.mean, colMeans, ...), so this
  // must not be conditional on finding one.
  const link = page.locator("#helpbox-wrapper section a").first();
  assert.equal(await link.count(), 1, "mean's help page has a See Also link");
  await link.click();
  await page.waitForFunction(
    (prev) => !document.querySelector("#helpbox-wrapper h1 code")?.innerText.includes(prev),
    "mean", { timeout: 15000 });

  assertNoProblems(page);
});

test("signature: the cursor after lm( shows a tooltip containing formula within 1s (61)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-signature.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("DF"));
  await page.locator(`${cellSelector("DF")} button.add_cell.after`).click({ force: true });
  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "DF");
  const newSel = `pluto-cell[id="${newCellId}"]`;

  const start = Date.now();
  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("lm(", { delay: 10 });
  await page.waitForSelector(".cm-ember-signature-tooltip", { timeout: 1000 });
  const text = await page.locator(".cm-ember-signature-tooltip").innerText();
  assert.match(text, /formula/);
  assert.ok(Date.now() - start < 1000);

  await page.screenshot({ path: path.join(artifactsDir(), "signature-tooltip-light.png") });
  await page.emulateMedia({ colorScheme: "dark" });
  await page.screenshot({ path: path.join(artifactsDir(), "signature-tooltip-dark.png") });
  await page.emulateMedia({ colorScheme: "light" });

  assertNoProblems(page);
});


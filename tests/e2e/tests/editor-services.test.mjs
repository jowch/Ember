// Piece 4 (docs/ui-2.md, "Editor services"), scenarios 59-61 of
// docs/ui-2-tests.md: completion, the help panel and the signature
// tooltip against a real server and worker. Go-to-definition (4e) is in
// go-to-definition.test.mjs.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector, setCellCode } from "../browser.mjs";

/** Resolves once the page hasn't scrolled for 10 frames in a row. The
 * check runs once a frame and returns a plain value: waitForFunction
 * awaits a returned Promise and takes its value as final, even a falsy
 * one, so a Promise-based check would never poll again. */
const scroll_settled = (page) => page.waitForFunction(() => {
  const s = (window.__scroll_settled ??= { y: null, frames: 0 });
  if (window.scrollY !== s.y) {
    s.y = window.scrollY;
    s.frames = 0;
    return false;
  }
  if (++s.frames < 10) return false;
  delete window.__scroll_settled;
  return true;
}, null, { polling: "raf", timeout: 30000 });

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

test("completion: typing me then Ctrl+Space lists mean; after running DF, df$ lists mpg (60)", { timeout: 120000 }, async (t) => {
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

test("completion still works on the notebook's names and base R while a cell runs (60)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-complete-busy.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "LOOP");
  await page.waitForFunction(
    () => document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running"),
    null, { timeout: 10000 });

  await page.hover(cellSelector("B"));
  const cellCountBefore = await page.locator("pluto-cell").count();
  await page.locator(`${cellSelector("B")} button.add_cell.after`).click({ force: true });
  await page.waitForFunction(
    (before) => document.querySelectorAll("pluto-cell").length > before,
    cellCountBefore, { timeout: 10000 });
  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "B");
  const newSel = `pluto-cell[id="${newCellId}"]`;

  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("su", { delay: 10 });
  const start = Date.now();
  await page.waitForSelector(".cm-tooltip-autocomplete .cm-completionLabel", { timeout: 5000 });
  assert.ok(Date.now() - start < 2000, "the fallback answered within 2s of the last keystroke while the worker was busy");
  const labels = await page.locator(".cm-tooltip-autocomplete .cm-completionLabel").allInnerTexts();
  assert.ok(labels.includes("sum"), `expected "sum" among ${JSON.stringify(labels)}`);

  assertNoProblems(page);
});

test("completion: typing a number asks R for nothing; a name typed after it still does (#35)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-complete-number.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // Each completion request's query_full (the cell's text up to the
  // cursor), read from the socket's msgpack: the string after its key,
  // whose header is one byte (fixstr) or two (str8).
  const queries = [];
  page.on("websocket", (ws) => ws.on("framesent", (frame) => {
    const m = Buffer.from(frame.payload).toString("latin1").match(/query_full(?:[\xa0-\xbf]|\xd9[\s\S])([\s\S]*?)\xabnotebook_id/);
    if (m) queries.push(m[1]);
  }));
  await openNotebook(page, server.origin, server.secret, notebook);

  // At a person's pace: CodeMirror asks its sources 100 ms after the last
  // keystroke, so typing faster than that would never ask after a digit.
  await page.locator(`${cellSelector("B")} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await page.keyboard.type("z <- c(12345, 2L, 3.14, 0x1F, 1i) + me", { delay: 150 });
  await page.waitForSelector(".cm-tooltip-autocomplete .cm-completionLabel", { timeout: 10000 });
  const labels = await page.locator(".cm-tooltip-autocomplete .cm-completionLabel").allInnerTexts();
  assert.ok(labels.includes("mean"), `expected "mean" among ${JSON.stringify(labels)}`);
  assert.ok(queries.some((q) => /\+ me?$/.test(q)), `a request for "me": ${JSON.stringify(queries)}`);
  assert.deepEqual(queries.filter((q) => /[0-9]$/.test(q)), [], "no request after a digit");

  assertNoProblems(page);
});

test("help: the cursor inside mean( shows Arithmetic Mean; a link loads another page; examples highlight as R (61)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-help.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "DF");
  // The worker answers "mean"'s help itself only when idle: process_status
  // "ready" (which also covers a busy worker) and no cell running or
  // queued. Opening the panel earlier gets "R is busy" and a retry, which
  // the next test covers on purpose.
  await page.waitForFunction(() => {
    const nb = window.editor_state?.notebook;
    return nb?.process_status === "ready" && nb.cell_results?.DF?.runtime != null &&
      Object.values(nb.cell_results).every((r) => !r.running && !r.queued);
  }, null, { timeout: 30000 });

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

  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "docs" })));
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
    (prev) => {
      const title = document.querySelector("#helpbox-wrapper .ember-help-page h2")?.innerText;
      return title != null && title !== prev;
    },
    "Arithmetic Mean", { timeout: 15000 });

  assertNoProblems(page);
});

test("help: opened while a cell runs, the panel says R is busy, then shows mean's page once the run ends, with no new keystroke (61)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-help-busy.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "LOOP");
  await page.waitForFunction(
    () => document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running"),
    null, { timeout: 10000 });

  await page.hover(cellSelector("B"));
  const cellCountBefore = await page.locator("pluto-cell").count();
  await page.locator(`${cellSelector("B")} button.add_cell.after`).click({ force: true });
  await page.waitForFunction(
    (before) => document.querySelectorAll("pluto-cell").length > before,
    cellCountBefore, { timeout: 10000 });
  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "B");
  const newSel = `pluto-cell[id="${newCellId}"]`;

  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("mean(x", { delay: 10 });
  await page.keyboard.press("Escape");
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "docs" })));

  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("R is busy running a cell"),
    null, { timeout: 15000 });
  assert.ok(
    await page.evaluate(() => document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running")),
    "LOOP was still running when the busy message showed");

  // LOOP runs for 8s; the panel must ask again on its own once R is free.
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("Arithmetic Mean"),
    null, { timeout: 30000 });

  assertNoProblems(page);
});

test("help: a query typed while R is busy is still a typed query when it's asked again (#92)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-help-busy-typed.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "LOOP");
  await page.waitForFunction(
    () => document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running"),
    null, { timeout: 10000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "docs" })));

  // `s` is mgcv's, installed but never attached: only a typed search
  // looks through every installed package (help-panel.test.mjs).
  await page.locator("#live-docs-search").fill("s");
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("R is busy running a cell"),
    null, { timeout: 15000 });

  // The retry once LOOP ends must keep the typed search's scope and
  // label: mgcv's page, and no "follows the cursor" line. If it never
  // comes, say what the panel shows and what the docs replies were.
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.includes("mgcv"),
    null, { timeout: 30000 }).catch(async (e) => {
    const seen = await page.evaluate(() => ({
      query: document.querySelector("#live-docs-search")?.value,
      package_line: document.querySelector(".ember-help-package")?.innerText ?? null,
      page: document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.slice(0, 300),
      loop_running: document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running"),
      replies: window.pluto_get_message_log().filter((m) => m.message?.doc !== undefined)
        .map((m) => [m.message.status, String(m.message.doc).replace(/<[^>]*>/g, "").slice(0, 80),
          // How far a 👍's lookup looked: asked to search every installed
          // package, and whether help() did (#121).
          ...(m.message.status === "👍" ? [{ all_packages: m.message.all_packages, tried_all_packages: m.message.tried_all_packages }] : [])]).slice(-12),
    }));
    throw new Error(`${e.message}\nthe panel: ${JSON.stringify(seen, null, 1)}`);
  });
  assert.equal(await page.locator(".ember-help-package").count(), 0, "no 'follows the cursor' line on a typed query's retry");
  assertNoProblems(page);
});

test("help: a typed query keeps its scope when the Help tab is closed and reopened while R is busy (#121)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-help-busy-reopen.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "LOOP");
  await page.waitForFunction(
    () => document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running"),
    null, { timeout: 10000 });
  const open_tab = (tab) => page.evaluate((tab) => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: tab })), tab);
  await open_tab("docs");
  await page.locator("#live-docs-search").fill("s");
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("R is busy running a cell"),
    null, { timeout: 15000 });

  // Another tab and back while R is still busy: the Help tab is a new
  // component, but the query is still the one typed, so it still looks
  // through every installed package and finds mgcv's `s`.
  await open_tab("variables");
  await page.waitForFunction(() => document.querySelector("#ember-variables-tab") != null, null, { timeout: 5000 });
  await open_tab("docs");
  assert.ok(await page.locator('pluto-cell[id="LOOP"]').evaluate((el) => el.classList.contains("running")),
    "LOOP was still running when the Help tab came back");
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.includes("mgcv"),
    null, { timeout: 30000 });
  assert.equal(await page.locator(".ember-help-package").count(), 0, "no 'follows the cursor' line on a typed query");
  assertNoProblems(page);
});

// #121's cause on macOS: the #92 test's fill() lands before the newly
// opened Help tab has run its first effects. Those effects then fetch the
// query the cursor had set (`sum`) before the typed `s`. The typed flag
// was once a one-shot ref that the first fetch used up, so `sum` went out
// as typed and `s` as a cursor query, which can't see mgcv. Here the
// typing comes in the same task as the opening, so it always comes first.
test("help: a query typed before the Help tab's first effects run keeps its typed scope (#121)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-help-typed-first.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // Docs requests as they're sent: only a docs request carries the msgpack
  // key `all_packages`. The message log holds only replies, which can't
  // arrive inside the evaluate below, so it can't show the order.
  await page.addInitScript(() => {
    window.__docs_sent = 0;
    const marker = new TextEncoder().encode("all_packages");
    const has_marker = (bytes) => {
      outer: for (let i = 0; i + marker.length <= bytes.length; i++) {
        for (let j = 0; j < marker.length; j++) if (bytes[i + j] !== marker[j]) continue outer;
        return true;
      }
      return false;
    };
    const send = WebSocket.prototype.send;
    WebSocket.prototype.send = function (data) {
      const bytes = data instanceof ArrayBuffer ? new Uint8Array(data)
        : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null;
      if (bytes != null && has_marker(bytes)) window.__docs_sent++;
      return send.call(this, data);
    };
  });
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "A");
  await page.waitForFunction(() => {
    const nb = window.editor_state?.notebook;
    return nb?.process_status === "ready" && nb.cell_results?.A?.runtime != null &&
      Object.values(nb.cell_results).every((r) => !r.running && !r.queued);
  }, null, { timeout: 30000 });

  await page.locator(`${cellSelector("B")} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.keyboard.press("Home");

  const effects_ran_first = await page.evaluate(async () => {
    window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "docs" }));
    // Preact renders in a microtask and runs effects after the next frame,
    // so waiting on microtasks alone gets the search box but no effects.
    let input = null;
    for (let i = 0; i < 100 && input == null; i++) {
      await Promise.resolve();
      input = document.querySelector("#live-docs-search");
    }
    if (input == null) return null;
    const before = window.__docs_sent;
    input.value = "s";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    return before > 0;
  });
  assert.equal(effects_ran_first, false, "the search box was there, and no docs request had gone out, when `s` was typed");

  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.includes("mgcv"),
    null, { timeout: 30000 }).catch(async (e) => {
    const seen = await page.evaluate(() => ({
      page: document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.slice(0, 300),
      replies: window.pluto_get_message_log().filter((m) => m.message?.doc !== undefined)
        .map((m) => [m.message.status, String(m.message.doc).replace(/<[^>]*>/g, "").slice(0, 80), m.message.all_packages]),
    }));
    throw new Error(`${e.message}\nthe panel: ${JSON.stringify(seen, null, 1)}`);
  });
  assert.equal(await page.locator(".ember-help-package").count(), 0, "no 'follows the cursor' line on a typed query");
  assertNoProblems(page);
});

// #132: a reply that arrives after a later query has gone out. `mean`'s
// request is held back past the panel's 2 s wait, so `s` is asked while
// it's still on the way, and `s` gets "R is busy" first. Then the page
// clock is paused, so `s`'s retry can't fire before `mean`'s late "R is
// busy" lands. That late reply used to cancel `s`'s retry, and the panel
// said R was busy for good.
test("help: a late \"R is busy\" for an older query doesn't cancel the current query's retry (#132)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-help-busy-late.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // Messages from the page to the server that mention `mean`, held while
  // `held` is a list.
  let held = null;
  let to_server = null;
  let on_held = null;
  const mean_held = new Promise((resolve) => (on_held = resolve));
  await page.routeWebSocket(/.*/, (ws) => {
    const srv = ws.connectToServer();
    to_server = srv;
    ws.onMessage((m) => {
      if (held != null && Buffer.from(m).includes("mean")) {
        held.push(m);
        on_held();
      } else srv.send(m);
    });
    srv.onMessage((m) => ws.send(m));
  });
  await page.clock.install();
  await openNotebook(page, server.origin, server.secret, notebook);

  // R must stay busy through all the setup below, however slow the
  // runner: 20 s, not the fixture's 8.
  await setCellCode(page, "LOOP", "t0 <- Sys.time(); while (Sys.time() - t0 < 20) NULL");
  await runCell(page, "LOOP");
  await page.waitForFunction(
    () => document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running"),
    null, { timeout: 10000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "docs" })));

  // `mean` replaces whatever the cursor asked for, and its request is held.
  // It goes out only once the cursor's own query has its answer, so the
  // wait below starts from `mean`'s request. The panel stops waiting for it
  // after 2 s, so the next query can go out.
  held = [];
  await page.locator("#live-docs-search").fill("mean");
  await mean_held;
  await page.waitForFunction(() => document.querySelector(".live-docs-searchbox")?.classList.contains("loading"), null, { timeout: 5000 });
  await page.waitForFunction(() => !document.querySelector(".live-docs-searchbox")?.classList.contains("loading"), null, { timeout: 15000 });

  // From here the clock moves only by hand: 100 ms lets the page draw and
  // send `s` (an effect waits for the next frame), well short of the 1 s
  // retry. Each "R is busy" reply is told apart by when it came.
  await page.clock.pauseAt(await page.evaluate(() => Date.now() + 1000));
  const mark_replies = () => page.evaluate(() => { window.__seen_messages = new Set(window.pluto_get_message_log()); });
  const new_busy_reply = () => page.waitForFunction(
    () => window.pluto_get_message_log().some((m) => m.message?.status === "⌛" && !window.__seen_messages.has(m)),
    null, { timeout: 15000 });
  await mark_replies();
  await page.locator("#live-docs-search").fill("s");
  await page.clock.runFor(100);
  await new_busy_reply();

  // `mean`'s request goes now, and R is still busy, so its reply is a
  // late "R is busy".
  await mark_replies();
  const release = held;
  held = null;
  for (const m of release) to_server.send(m);
  await new_busy_reply();
  assert.ok(await page.locator('pluto-cell[id="LOOP"]').evaluate((el) => el.classList.contains("running")),
    "LOOP was still running when mean's late reply came");

  // The clock runs again. `s` must still be asked again once LOOP ends,
  // and find mgcv's page.
  await page.clock.resume();
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.includes("mgcv"),
    null, { timeout: 45000 });
  assert.equal(await page.locator("#live-docs-search").inputValue(), "s");
  assertNoProblems(page);
});

test("help: a search that finds nothing once R is free replaces \"R is busy\" (#121)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-help-busy-notfound.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "LOOP");
  await page.waitForFunction(
    () => document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running"),
    null, { timeout: 10000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "docs" })));

  await page.locator("#live-docs-search").fill("zzznotatopic");
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("R is busy running a cell"),
    null, { timeout: 15000 });

  // Once LOOP ends the retry finds nothing. The page must say so, not
  // keep saying R is busy.
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.includes("No help page for zzznotatopic"),
    null, { timeout: 30000 });
  assert.doesNotMatch(await page.locator("#helpbox-wrapper .ember-help-page").innerText(), /R is busy/);
  assertNoProblems(page);
});

test("signature: the cursor after lm( shows a tooltip containing formula within 1s (62)", async (t) => {
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

  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("lm", { delay: 10 });
  const start = Date.now();
  await page.keyboard.type("(");
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

// #34: the tooltip sits above the call's line. For a call on a cell's
// first line that is over the cell before it, and a click there must reach
// that cell, not the tooltip.
test("signature: a click on the tooltip lands in the code under it (#34)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-signature-click.server.log") });
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

  // How far the tooltip reaches up depends on fonts and how the signature
  // wraps, which differ by platform. A minimum height makes it cover DF's
  // line on every platform; what this test checks is where the click goes.
  await page.addStyleTag({ content: ".cm-ember-signature-tooltip { min-height: 8em; }" });

  // CodeMirror puts the tooltip above the line only if there is room when
  // it first shows it, and once it has put it below it keeps it there
  // while it fits (#100). So the cell must be in the middle of the window,
  // with every scroll finished, before the tooltip opens. A new cell
  // focuses itself on a timer and scrolls itself into view (smoothly,
  // focus_after_creation in CellInput.js); wait for that focus and for the
  // page to stop scrolling, then centre the cell and wait again.
  await page.waitForSelector(`${newSel} .cm-editor.cm-focused`, { timeout: 30000 });
  await scroll_settled(page);
  await page.locator(newSel).evaluate((el) => el.scrollIntoView({ block: "center" }));
  await scroll_settled(page);

  await page.keyboard.type("read.table(", { delay: 10 });
  const tooltip = page.locator(".cm-ember-signature-tooltip");
  await tooltip.waitFor({ timeout: 30000 });
  // Created first, placed on CodeMirror's next measure.
  await page.waitForSelector(".cm-ember-signature-tooltip.cm-tooltip-above, .cm-ember-signature-tooltip.cm-tooltip-below", { timeout: 30000 });
  const where = async () => JSON.stringify({
    tooltip: await tooltip.boundingBox(),
    class: await tooltip.getAttribute("class"),
    cell: await page.locator(newSel).boundingBox(),
    df_line: await page.locator(`${cellSelector("DF")} .cm-editor:not(.cm-ssr-fake) .cm-line`).first().boundingBox(),
    scrollY: await page.evaluate(() => window.scrollY),
  });
  const placed = await where();
  if (!/cm-tooltip-above/.test(await tooltip.getAttribute("class"))) {
    await page.screenshot({ path: path.join(artifactsDir(), "editor-signature-click-placement.png") });
  }
  assert.match(await tooltip.getAttribute("class"), /cm-tooltip-above/, `the tooltip is above the call's line: ${placed}`);

  // Click in the middle of where the tooltip and DF's line overlap.
  const box = await tooltip.boundingBox();
  const df_line = await page.locator(`${cellSelector("DF")} .cm-editor:not(.cm-ssr-fake) .cm-line`).first().boundingBox();
  const left = Math.max(box.x, df_line.x), right = Math.min(box.x + box.width, df_line.x + df_line.width);
  const top = Math.max(box.y, df_line.y), bottom = Math.min(box.y + box.height, df_line.y + df_line.height);
  assert.ok(left < right && top < bottom, `the tooltip covers DF's line: ${placed}`);
  const x = (left + right) / 2;
  const y = (top + bottom) / 2;

  await page.mouse.click(x, y);
  await tooltip.waitFor({ state: "detached", timeout: 30000 });
  await page.keyboard.type("Z");
  assert.match(await page.locator(`${cellSelector("DF")} .cm-line`).first().innerText(), /Z/, "the click put the cursor in DF");
  assert.equal(await page.locator(`${newSel} .cm-line`).first().innerText(), "read.table()", "the new cell is unchanged");

  assertNoProblems(page);
});

// #103: with no room above (the cell just under the header), CodeMirror
// puts the tooltip below the line it is anchored to. In a call that spans
// several lines, that line must be the cursor's, not the call's first, or
// the tooltip covers the line being typed.
test("signature: in a multi-line call at the top of the window, the tooltip leaves the cursor's line visible (#103)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-signature-multiline.server.log") });
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

  // As in #34's test: wait out the new cell's own focus and smooth scroll,
  // then put the cell right under the header, and wait again.
  await page.waitForSelector(`${newSel} .cm-editor.cm-focused`, { timeout: 30000 });
  await scroll_settled(page);
  await page.locator(newSel).evaluate((el) => {
    const header = document.querySelector("header")?.getBoundingClientRect().bottom ?? 0;
    window.scrollBy({ top: el.getBoundingClientRect().top - header, behavior: "instant" });
  });
  await scroll_settled(page);

  await page.keyboard.type("read.table(", { delay: 10 });
  await page.waitForSelector(".cm-ember-signature-tooltip.cm-tooltip-above, .cm-ember-signature-tooltip.cm-tooltip-below", { timeout: 30000 });
  // Enter only: typing an argument would open the completion popup, and
  // CodeMirror moves the tooltip clear of it.
  await page.keyboard.press("Enter");

  // Wait until the cursor's line and the tooltip have held still for 10
  // frames (the debounced re-anchor and CodeMirror's measure both land on
  // later frames); both are read in the same frame.
  const placed = await page.waitForFunction(() => {
    const tooltip = document.querySelector(".cm-ember-signature-tooltip");
    const editor = document.querySelector(".cm-editor.cm-focused");
    const cursor = editor?.querySelector(".cm-cursor");
    if (tooltip == null || cursor == null || !/cm-tooltip-(above|below)/.test(tooltip.className)) return false;
    // The text the cursor is in spans the caret's own box (the line's box
    // is a little taller, and CodeMirror places the tooltip from the text).
    const c = cursor.getBoundingClientRect(), t = tooltip.getBoundingClientRect();
    const line_number = Array.from(editor.querySelectorAll(".cm-line")).findIndex((l) => {
      const b = l.getBoundingClientRect();
      return c.top + c.height / 2 > b.top && c.top + c.height / 2 < b.bottom;
    }) + 1;
    const now = { tooltip: [t.top, t.bottom], cursor: [c.top, c.bottom], line_number, class: tooltip.className };
    const s = (window.__placed ??= { last: null, frames: 0 });
    const key = JSON.stringify(now);
    if (key !== s.last) {
      s.last = key;
      s.frames = 0;
      return false;
    }
    if (++s.frames < 10) return false;
    delete window.__placed;
    return now;
  }, null, { polling: "raf", timeout: 30000 }).then((h) => h.jsonValue());

  assert.equal(placed.line_number, 2, `the cursor is on the call's second line: ${JSON.stringify(placed)}`);
  // #103 only happens below the line: with room above, main passes too.
  assert.match(placed.class, /cm-tooltip-below/, `no room above, so the tooltip goes below: ${JSON.stringify(placed)}`);
  const overlap = Math.min(placed.tooltip[1], placed.cursor[1]) - Math.max(placed.tooltip[0], placed.cursor[0]);
  assert.ok(overlap <= 0, `the tooltip doesn't cover the text being typed: ${JSON.stringify(placed)}`);

  assertNoProblems(page);
});

test("brackets: the bracket at the cursor and its partner are marked, for every R bracket; one inside a string isn't paired (#246)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-brackets.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  //          0         1         2         3
  //          0123456789012345678901234567890
  const code = 'f(c(1), {2}, x[3], y[[4]], "(")';
  await setCellCode(page, "A", code);
  const content = page.locator(`${cellSelector("A")} .cm-content`);
  const marks = `${cellSelector("A")} .cm-matchingBracket`;
  const marked = () => page.evaluate((sel) => [...document.querySelectorAll(sel)].map((e) => e.textContent), marks);
  const cursor_at = async (pos) => {
    await content.click();
    await page.keyboard.press("Home");
    for (let i = 0; i < pos; i++) await page.keyboard.press("ArrowRight");
  };
  const marks_become = (n) => page.waitForFunction(([sel, n]) => document.querySelectorAll(sel).length === n, [marks, n], { timeout: 30000 });

  // [cursor position, what it sits next to, the pair expected]
  const cases = [
    [2, "a call's (", ["(", ")"]],
    [4, "the inner call's (", ["(", ")"]],
    [6, "a closing )", ["(", ")"]],
    [9, "{", ["{", "}"]],
    [11, "a closing }", ["{", "}"]],
    [15, "[", ["[", "]"]],
    [17, "a closing ]", ["[", "]"]],
    [22, "[[", ["[", "]"]],
    [31, "the last )", ["(", ")"]],
  ];
  for (const [pos, what, pair] of cases) {
    await cursor_at(pos);
    await marks_become(2);
    assert.deepEqual((await marked()).sort(), [...pair].sort(), `next to ${what} (position ${pos}), both brackets are marked`);
  }

  // From a marked pair to the ( inside the string: that ( is text, so it
  // isn't paired with the call's closing ). (A bracket with no partner is
  // still marked on its own, as before.)
  await cursor_at(2);
  await marks_become(2);
  for (let i = 2; i < 29; i++) await page.keyboard.press("ArrowRight");
  await page.waitForFunction((sel) => document.querySelectorAll(sel).length !== 2, marks, { timeout: 30000 });
  assert.ok(!(await marked()).includes(")"), `the ( in the string isn't paired: ${JSON.stringify(await marked())}`);

  assertNoProblems(page);
});

// #314: select all and retype while the tooltip shows. The first key
// shortens the code below the tooltip's anchor; the tooltip must follow
// the edit instead of being measured at a position past the end, which
// threw, rebuilt the editor and dropped every later keystroke.
test("signature: select all and retype inside a call keeps every key (#314)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "editor-signature-retype.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "A");
  await page.waitForFunction(() => window.editor_state.notebook.cell_results.A?.output?.last_run_timestamp > 0, null, { timeout: 30000 });

  // A call over two lines: the cell gets shorter on the first key, so
  // CodeMirror measures the tooltip straight away (on a one-line cell it
  // waits for the next scroll, which in a person's session comes soon
  // enough but not in a test).
  await setCellCode(page, "B", "mean(c(x,\n1, 2, 3, 4))");
  const content = page.locator(`${cellSelector("B")} .cm-editor:not(.cm-ssr-fake) .cm-content`);
  await page.keyboard.press("ArrowLeft");
  await page.keyboard.press("ArrowLeft");
  await page.keyboard.press("ArrowLeft");
  await page.waitForSelector(".cm-ember-signature-tooltip", { timeout: 30000 });

  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await page.keyboard.type("x * 10", { delay: 120 });

  assert.equal(await content.innerText(), "x * 10");
  assert.ok(await page.evaluate(() => document.activeElement?.closest?.("pluto-cell")?.id === "B"), "focus stays in the cell");
  assertNoProblems(page);
});

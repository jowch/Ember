// Piece 1 ("Ember's look"), docs/ui-2-tests.md items 8-12: the page says
// Ember, not Pluto/Julia; the deleted features (AI, feedback, disable/skip
// cell, hide logs) stay gone; markdown cells render folded with R inside
// fenced blocks; Endeavor's DOM hooks survive.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// 8. Logo, title, no Pluto/Julia text, no console errors.
test("look: logo, title and body text say Ember, not Pluto/Julia (8)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ember-look-8.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // 124: the header's logo is an inline SVG, drawn in --ember-logo, not
  // img#logo-big/img#logo-small (those stay for exports and the start page).
  const fill = await page.locator("header#pluto-nav h1 svg").evaluate((el) => getComputedStyle(el.querySelector("g")).fill);
  assert.equal(fill, "rgb(232, 89, 12)");
  await page.emulateMedia({ colorScheme: "dark" });
  await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "dark", null, { timeout: 5000 });
  const darkFill = await page.locator("header#pluto-nav h1 svg").evaluate((el) => getComputedStyle(el.querySelector("g")).fill);
  assert.equal(darkFill, "rgb(240, 112, 50)");
  await page.emulateMedia({ colorScheme: "light" });
  await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "light", null, { timeout: 5000 });

  assert.match(await page.title(), /^basic\.R — Ember$/);

  const bodyText = await page.locator("body").innerText();
  assert.doesNotMatch(bodyText, /Pluto/);
  assert.doesNotMatch(bodyText, /Julia/);

  assertNoProblems(page);
});

// 9. No calls to Pluto's/the AI/the analytics servers; no "Fix with AI".
test("look: no requests to external calling-home servers; no Fix with AI (9)", async (t) => {
  // rich.R's PARSE cell (`x <- (`) is a parse error from the file itself,
  // so its error is already in the very first snapshot the page renders
  // (unlike a parse error freshly typed into a brand-new cell, whose
  // CellOutput mounts before the error exists and then never updates,
  // because `last_run_timestamp` stays 0 for a cell that can never run --
  // a pre-existing, unrelated CellOutput.js gating quirk, not piece 1's).
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ember-look-9.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  const requestedHosts = [];
  page.on("request", (req) => { try { requestedHosts.push(new URL(req.url()).hostname); } catch { /* ignore */ } });

  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForSelector(`${cellSelector("PARSE")} jlerror.syntax-error`, { timeout: 20000 });

  const blocked = ["plutojl.org", "fonsp.com", "openai.com", "gstatic.com", "api.github.com"];
  for (const host of blocked) {
    assert.ok(!requestedHosts.some((h) => h.endsWith(host)), `no request to ${host}`);
  }

  const fixWithAi = await page.locator(`${cellSelector("PARSE")} .fix-with-ai, ${cellSelector("PARSE")} [class*="fix-with-ai"]`).count();
  assert.equal(fixWithAi, 0, "no Fix with AI button next to the parse error");

  assertNoProblems(page);
});

// 10. Cell menu: Delete + Copy output + Disable cell only, no deleted
// actions; no feedback form. (ui-3 piece 1b adds "Disable cell" for a
// non-setup code cell.)
test("look: cell menu has only Delete/Copy output/Disable cell; no feedback form (10)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ember-look-10.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  // The ⋯ trigger only takes clicks while its cell is hovered or
  // focused (cells.css; it's otherwise pointer-events: none, hidden).
  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  const menuItems = await page.locator(`${cellSelector("B")} .input_context_menu ul li button`).evaluateAll(
    (btns) => btns.map((b) => b.className));
  assert.ok(menuItems.some((c) => c.includes("delete")), "Delete cell is offered");
  assert.ok(menuItems.some((c) => c.includes("copy_output")), "Copy output is offered");
  assert.ok(menuItems.some((c) => c.includes("disable_cell")), "Disable cell is offered");
  for (const forbidden of ["ask_ai", "skip_as_script", "hide_logs", "show_logs"]) {
    assert.ok(!menuItems.some((c) => c.includes(forbidden)), `${forbidden} is not offered`);
  }

  assert.equal(await page.locator("form#feedback").count(), 0, "no feedback form on the page");
  // 125: the footer (Settings/FAQ links) is gone; Settings lives in the
  // header's ⋯ menu now.
  assert.equal(await page.locator("footer").count(), 0, "no footer element");

  assertNoProblems(page);
});

// 11. Markdown cells: folded by default, R-highlighted fenced block inside.
test("look: markdown cell renders folded, with R tokens in its fenced block (11)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ember-look-11.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // Markdown never runs, so safe preview shows it rendered and folded too.
  const previewFolded = await page.locator(cellSelector("MD")).evaluate((el) => el.classList.contains("code_folded"));
  assert.ok(previewFolded, "MD is folded in safe preview");
  assert.match(await page.locator(`${cellSelector("MD")} pluto-output`).innerText(), /Rich outputs/);

  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(() => document.querySelectorAll("#ember-safe-preview").length === 0, null, { timeout: 20000 });

  const isFolded = await page.locator(cellSelector("MD")).evaluate((el) => el.classList.contains("code_folded"));
  assert.ok(isFolded, "MD starts folded");
  const renderedText = await page.locator(`${cellSelector("MD")} pluto-output`).innerText();
  assert.match(renderedText, /Rich outputs/);

  // R tokens, not just the raw "```r" fence text: highlight.js actually
  // tokenized the fenced block's "1 + 1" (a number and an operator -- no
  // keyword in this fixture, so `.hljs-number` is the real span to expect).
  // This output isn't affected by the cell's own code-fold state.
  const hasHighlightToken = await page.locator(`${cellSelector("MD")} pluto-output .hljs-number`).count();
  assert.ok(hasHighlightToken > 0, "expected the fenced R block to carry a highlight.js token span");

  // Unfold: click the fold toggle. The design's check reads the syntax
  // tree's top node through CodeMirror 6's EditorView.findFromDOM, but a
  // freshly unfolded cell first mounts a non-interactive "static fake"
  // (CellInput.js's StaticCodeMirrorFaker, a lazy-rendering optimisation
  // promoted to the real instance by an IntersectionObserver) that never
  // promoted within this headless run, independent of cell kind -- so this
  // checks the same fact (markdown source, fenced R block, vs. a code
  // cell's bare R) through the rendered text instead.
  // The fold eye is hidden now (ui-3-plan.md piece 6a): Hide/Show code
  // moved to the cell menu, which still toggles the same code_folded flag.
  await page.hover(cellSelector("MD"));
  await page.locator(`${cellSelector("MD")} button.input_context_menu`).click();
  await page.locator(`${cellSelector("MD")} button.hide_code`).click();
  const mdSource = await page.locator(`${cellSelector("MD")} .cm-content`).innerText();
  assert.match(mdSource, /```r/, "the unfolded source keeps the fenced R block");
  assert.match(mdSource, /1 \+ 1/);

  const codeFolded = await page.locator(cellSelector("DF")).evaluate((el) => el.classList.contains("code_folded"));
  assert.equal(codeFolded, false, "a code cell is not folded");
  const dfSource = await page.locator(`${cellSelector("DF")} .cm-content`).innerText();
  assert.doesNotMatch(dfSource, /```/, "a code cell's source has no markdown fencing");

  assertNoProblems(page);
});

// 12. Endeavor's DOM hooks survive.
test("look: Endeavor's DOM hooks are present (12)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ember-look-12.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  assert.ok(await page.locator("header").count() > 0);
  assert.ok(await page.locator("main pluto-notebook").count() > 0);
  assert.ok(await page.locator("pluto-output").count() > 0);
  assert.ok(await page.locator(`${cellSelector("B")} .cm-content`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("B")} button.add_cell.before`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("B")} button.add_cell.after`).count() > 0);

  const cellOrder = await page.evaluate(() => window.editor_state?.notebook?.cell_order);
  assert.ok(Array.isArray(cellOrder) && cellOrder.length > 0, "window.editor_state.notebook.cell_order exists");

  // Every variable Pluto's theme defines, plus the ones Endeavor's page code
  // reads from :root (endeavor-css-variables.txt; Endeavor also reads
  // --indented, which CodeMirror sets per line, not on :root).
  const varsPath = path.join(HERE, "..", "..", "testthat", "fixtures", "pluto-css-variables.txt");
  // A few variables are defined as the literal value `inherit` in one or
  // both themes, which (correctly) resolves to the empty string at `:root`
  // (no parent to inherit from); they only resolve once used inside a rule
  // that has one, which this broad :root check can't exercise.
  const inheritValued = new Set(["--pluto-logs-info-accent-color", "--blockquote-color"]);
  const endeavorPath = path.join(HERE, "..", "..", "testthat", "fixtures", "endeavor-css-variables.txt");
  const names = [varsPath, endeavorPath].flatMap((p) => fs.readFileSync(p, "utf8").split("\n"))
    .map((l) => l.trim()).filter(Boolean).filter((n) => !inheritValued.has(n));
  for (const scheme of ["light", "dark"]) {
    await page.emulateMedia({ colorScheme: scheme });
    const values = await page.evaluate((ns) => {
      const style = getComputedStyle(document.documentElement);
      return ns.map((n) => style.getPropertyValue(n).trim());
    }, names);
    const empty = names.filter((_, i) => values[i] === "");
    assert.deepEqual(empty, [], `every CSS variable resolves on :root under ${scheme}`);
  }

  assertNoProblems(page);
});

// With no custom code font set (the default), the code box must actually
// show Ember's own font (IBM Plex Mono), not fall back to the browser's
// bare "monospace" generic (Notebook.js used to substitute the literal
// string "monospace" for an empty setting, which beat the real fallback).
test("look: with no custom code font set, cm-content renders in IBM Plex Mono, not plain monospace", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ember-look-font.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // getComputedStyle's font-family is the whole specified list, not the
  // one family actually rendering -- --custom-code-font-stack's unset
  // value is the quoted empty string (editor.css's :root default, a
  // legal placeholder that intentionally matches nothing), so the first
  // *meaningful* family is what matters here, not literally the first
  // entry.
  const families = await page.locator(`${cellSelector("B")} .cm-content`).evaluate((el) => {
    return getComputedStyle(el).fontFamily.split(",").map((f) => f.trim().replace(/^["']|["']$/g, ""));
  });
  const firstMeaningful = families.find((f) => f !== "");
  assert.notEqual(firstMeaningful.toLowerCase(), "monospace", "the first real font family is not the bare generic");
  assert.equal(firstMeaningful, "IBM Plex Mono");

  assertNoProblems(page);
});

// 123. Endeavor's panel hooks: #helpbox-wrapper, pluto-helpbox > header,
// #live-docs-search once Help is open; open_bottom_right_panel(null) closes
// it; header#pluto-nav and main pluto-notebook still exist.
test("look: Endeavor's panel hooks are present (123)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ember-look-123.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  assert.ok(await page.locator("header#pluto-nav").count() > 0);
  assert.ok(await page.locator("main pluto-notebook").count() > 0);

  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "docs" })));
  await page.waitForSelector("#live-docs-search");
  assert.ok(await page.locator("#helpbox-wrapper").count() > 0);
  assert.ok(await page.locator("pluto-helpbox > header").count() > 0);

  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: null })));
  await page.waitForSelector("#helpbox-wrapper:not(.open)", { state: "attached" });

  assertNoProblems(page);
});

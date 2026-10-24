// ui-3-tests.md test 37 (piece 1b, "Disable cell"): the cell menu disables
// and re-enables a cell; a disabled cell and its dependent dim and keep
// their last output; the file is written with "## " and "disabled"; the
// classes and file survive a reload.

import { test } from "node:test";
import path from "node:path";
import fs from "node:fs";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";
import { poll } from "../waits.mjs";

test("disable cell: toggling off then on, with the file and classes surviving a reload (37)", async (t) => {
  const notebook = tempNotebook("disabled.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "disabled.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator("#ember-safe-preview button").click();

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output");

  await page.hover(cellSelector("S"));
  await page.locator(`${cellSelector("S")} button.input_context_menu`).click();
  assert.equal(await page.locator(`${cellSelector("S")} button.disable_cell`).count(), 1,
    "the first cell's menu has a disable item: no cell is special");
  await page.keyboard.press("Escape");

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  const disableItem = page.locator(`${cellSelector("A")} button.disable_cell`);
  assert.equal(await disableItem.innerText(), "Disable cell");
  await disableItem.click();

  await page.waitForSelector(`${cellSelector("A")}.running_disabled`);
  await page.waitForSelector(`${cellSelector("B")}.depends_on_disabled_cells`);
  assert.equal(await page.locator(`${cellSelector("C")}.running_disabled`).count(), 0);
  assert.equal(await page.locator(`${cellSelector("C")}.depends_on_disabled_cells`).count(), 0);

  let onDisk = "";
  await poll("the file has A disabled", () => (onDisk = fs.readFileSync(notebook, "utf8")).includes("## x <- 1"), () => onDisk);
  assert.match(onDisk, /## x <- 1/);
  assert.match(onDisk, /# A disabled/);

  await page.reload();
  await page.waitForSelector("pluto-cell");
  await page.waitForFunction(
    () => !document.querySelector("pluto-editor")?.classList.contains("loading"));

  await page.waitForSelector(`${cellSelector("A")}.running_disabled`);
  assert.equal(await page.locator(`${cellSelector("B")}.depends_on_disabled_cells`).count(), 1);

  const beforeEnable = await page.evaluate(() => {
    const cr = window.editor_state.notebook.cell_results;
    return { aTs: cr["A"]?.output?.last_run_timestamp ?? 0, bTs: cr["B"]?.output?.last_run_timestamp ?? 0 };
  });

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  const enableItem = page.locator(`${cellSelector("A")} button.disable_cell`);
  assert.equal(await enableItem.innerText(), "Enable cell");
  await enableItem.click();

  await page.waitForFunction(
    (sel) => !document.querySelector(sel)?.classList.contains("running_disabled"),
    cellSelector("A"));
  await page.waitForFunction(
    (sel) => !document.querySelector(sel)?.classList.contains("depends_on_disabled_cells"),
    cellSelector("B"));

  // B's dimmed/stale state genuinely clears (not just the CSS class driven
  // by depends_on_disabled_cells), and A really reran -- its own run
  // timestamp moved on, not merely its disabled flag flipping -- which in
  // turn is what reruns B in autorun.
  await page.waitForFunction(
    (before) => {
      const cr = window.editor_state.notebook.cell_results;
      const aTs = cr["A"]?.output?.last_run_timestamp ?? 0;
      const bTs = cr["B"]?.output?.last_run_timestamp ?? 0;
      return cr["B"]?.ember?.stale === false && aTs > before.aTs && bTs > before.bTs;
    },
    beforeEnable);

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output");

  assertNoProblems(page);
});

test("undo delete of a disabled cell brings it back disabled, under its short id (#26, #27)", async (t) => {
  const notebook = tempNotebook("disabled.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "disabled-undo.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output");

  // The page marks a cell queued itself when it asks to run it (after a
  // disable, and after an undo); the server's answer clears it. Count the
  // acknowledged run requests for A, then wait for A to be idle.
  await page.evaluate(() => {
    window.__a_acks = 0;
    window.addEventListener("ember_run_acknowledged", (e) => { if (e.detail.cell_ids.includes("A")) window.__a_acks++; });
  });
  const idleAfterAck = (n) => page.waitForFunction((n) => {
    const r = window.editor_state.notebook.cell_results["A"];
    return window.__a_acks >= n && r && !r.running && !r.queued;
  }, n);

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  await page.locator(`${cellSelector("A")} button.disable_cell`).click();
  await page.waitForSelector(`${cellSelector("A")}.running_disabled`);
  await page.keyboard.press("Escape");   // close the cell menu
  await idleAfterAck(1);   // else the delete asks to stop A first

  await page.evaluate(() => document.getElementById("A").focus());
  await page.evaluate(() => window.editor_state_set({ selected_cells: ["A"] }));
  await page.keyboard.press("Backspace");
  await page.waitForFunction(() => !window.editor_state.notebook.cell_order.includes("A"));
  await page.waitForSelector("nav#undo_delete:not(.hidden)");
  const fileSays = async (re, want) => {
    let text = "";
    await poll(`the file ${want ? "matches" : "doesn't match"} ${re}`, () => re.test(text = fs.readFileSync(notebook, "utf8")) === want, () => text);
    return text;
  };
  assert.doesNotMatch(await fileSays(/# %% id=A\n/, false), /# %% id=A\n/, "the delete was saved");
  await page.locator("#undo_delete a").click();

  // Back under its own id, disabled, and its dependent off again; the
  // page's run request after the undo doesn't run it.
  await page.waitForSelector(`${cellSelector("A")}.running_disabled`);
  await page.waitForSelector(`${cellSelector("B")}.depends_on_disabled_cells`);
  assert.deepEqual(await page.evaluate(() => window.editor_state.notebook.cell_order), ["S", "A", "B", "C"]);
  const onDisk = await fileSays(/# %% id=A\n/, true);
  assert.match(onDisk, /# %% id=A\n## x <- 1/);
  assert.match(onDisk, /# A disabled/);
  await idleAfterAck(2);
  const a = await page.evaluate(() => window.editor_state.notebook.cell_results["A"]);
  assert.ok(!a?.output?.last_run_timestamp, "A never ran after the undo");
  // No "cell id must be a UUID" refusal logged by the page (#27).
  assertNoProblems(page);
});

test("a disabled cell reads at 3 : 1 or better: its greyed output and its uncoloured code, in both themes (#591)", async (t) => {
  const notebook = tempNotebook("disabled.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "disabled-contrast.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output");

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  await page.locator(`${cellSelector("A")} button.disable_cell`).click();
  await page.waitForSelector(`${cellSelector("A")}.running_disabled`);
  await page.waitForSelector(`${cellSelector("B")}.depends_on_disabled_cells`);
  await page.keyboard.press("Escape");
  await page.mouse.move(0, 0);

  const parse = (c) => c.match(/[\d.]+/g).map(Number);
  const lum = ([r, g, b]) => {
    const [R, G, B] = [r, g, b].map((v) => v / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * R + 0.7152 * G + 0.0722 * B;
  };
  const contrast = (a, b) => { const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x); return (hi + 0.05) / (lo + 0.05); };
  // CSS grayscale(1) is the luminance-weighted sum per channel.
  const grey = ([r, g, b]) => { const y = 0.2126 * r + 0.7152 * g + 0.0722 * b; return [y, y, y]; };

  for (const scheme of ["light", "dark"]) {
    await page.emulateMedia({ colorScheme: scheme });
    await page.waitForFunction((scheme) => document.documentElement.dataset.theme === scheme, scheme);

    // B's output, greyed and faded over the page.
    const out = await page.locator(`${cellSelector("B")} > pluto-output`).evaluate((el) => {
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      const colours = [];
      for (let n = walker.nextNode(); n != null; n = walker.nextNode()) {
        if (n.textContent.trim() !== "") colours.push(getComputedStyle(n.parentElement).color);
      }
      const style = getComputedStyle(el);
      return { colours, opacity: style.opacity, filter: style.filter, page: getComputedStyle(document.body).backgroundColor };
    });
    assert.ok(out.colours.length > 0, `${scheme}: B's output has text`);
    assert.match(out.filter, /grayscale\(1\)/, `${scheme}: B's output is greyed`);
    const a = Number(out.opacity);
    assert.ok(a < 1, `${scheme}: B's output is faded (${a})`);
    const under = parse(out.page);
    for (const c of out.colours) {
      const seen = grey(parse(c)).map((v, i) => v * a + under[i] * (1 - a));
      const ratio = contrast(seen, under);
      assert.ok(ratio >= 3, `${scheme}: B's output text ${c} reads at ${ratio.toFixed(2)} : 1`);
    }

    // A's code and line numbers on its grey background, at full opacity.
    const code = await page.locator(`${cellSelector("A")} > pluto-input .cm-editor`).evaluate((ed) => {
      const texts = [];
      for (const part of [ed.querySelector(".cm-content"), ed.querySelector(".cm-gutters")]) {
        const walker = document.createTreeWalker(part, NodeFilter.SHOW_TEXT);
        for (let n = walker.nextNode(); n != null; n = walker.nextNode()) {
          if (n.textContent.trim() === "") continue;
          let opacity = 1;
          for (let e = n.parentElement; e != null && e !== ed; e = e.parentElement) opacity *= Number(getComputedStyle(e).opacity);
          texts.push({ text: n.textContent, colour: getComputedStyle(n.parentElement).color, opacity });
        }
      }
      return { texts, bg: getComputedStyle(ed).backgroundColor };
    });
    assert.ok(code.texts.some((x) => x.text.includes("x")), `${scheme}: A's code is there`);
    for (const x of code.texts) {
      assert.equal(x.opacity, 1, `${scheme}: "${x.text}" in A's code isn't faded`);
      const ratio = contrast(parse(x.colour), parse(code.bg));
      assert.ok(ratio >= 3, `${scheme}: "${x.text}" in A's code reads at ${ratio.toFixed(2)} : 1`);
    }
  }
  assertNoProblems(page);
});

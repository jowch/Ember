// The keyboard path and the focus ring, tests 166 and 167 of
// docs/ui-3-tests.md (piece 7e).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

/** What has focus: the element's tag, cell id, classes and accessible name. */
function focused(page) {
  return page.evaluate(() => {
    const el = document.activeElement;
    return {
      tag: el?.tagName.toLowerCase(),
      cell: el?.closest("pluto-cell")?.id ?? null,
      cm_content: el?.matches(".cm-content") ?? false,
      selected: el?.classList.contains("selected") ?? false,
      label: el?.getAttribute("aria-label") ?? null,
      text: el?.textContent.trim() ?? "",
      in_panel: el?.closest("#helpbox-wrapper") != null,
    };
  });
}

test("keyboard path: skip link, Esc selects the cell, arrows, Enter, Tab to run, Esc closes the panel (166)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "keyboard-166.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const order = await page.evaluate(() => window.editor_state.notebook.cell_order);

  await page.keyboard.press("Tab");
  const skip = await page.evaluate(() => {
    const el = document.activeElement;
    const r = el.getBoundingClientRect();
    return { cls: el.className, text: el.textContent.trim(), width: r.width, height: r.height };
  });
  assert.equal(skip.cls, "skip-link");
  assert.equal(skip.text, "Skip to the notebook");
  assert.ok(skip.width > 40 && skip.height > 20, `the focused skip link is visible: ${JSON.stringify(skip)}`);

  await page.keyboard.press("Enter");
  let f = await focused(page);
  assert.equal(f.cell, order[0]);
  assert.ok(f.cm_content, "Enter puts focus in the first cell's code");

  await page.keyboard.press("Escape");
  f = await focused(page);
  assert.deepEqual([f.tag, f.cell, f.selected], ["pluto-cell", order[0], true]);

  await page.keyboard.press("ArrowDown");
  f = await focused(page);
  assert.deepEqual([f.tag, f.cell, f.selected], ["pluto-cell", order[1], true]);
  assert.deepEqual(await page.evaluate(() => window.editor_state.selected_cells), [order[1]]);

  await page.keyboard.press("Enter");
  f = await focused(page);
  assert.equal(f.cell, order[1]);
  assert.ok(f.cm_content, "Enter puts focus in the selected cell's code");

  // Board A11y6: run and ⋯ show while typing and on the button Tab reaches, not on a selected cell.
  await page.mouse.move(0, 0);
  const controls = (want) => page.waitForFunction(([id, want]) => {
    const cell = document.querySelector(`pluto-cell[id="${id}"]`);
    const shown = (sel) => getComputedStyle(cell.querySelector(sel)).opacity === "1";
    return JSON.stringify([shown("button.ember-run"), shown("button.input_context_menu")]) === JSON.stringify(want);
  }, [order[1], want], { timeout: 3000 });
  await controls([true, true]);
  await page.keyboard.press("Escape");
  await controls([false, false]);
  await page.keyboard.press("Tab");
  await controls([true, false]);
  f = await focused(page);
  assert.deepEqual([f.tag, f.cell, f.label], ["button", order[1], "Run cell (Shift + Enter)"]);

  await page.getByRole("button", { name: "Help", exact: true }).click();
  await page.waitForSelector("#helpbox-wrapper.open", { timeout: 5000 });
  await page.waitForFunction(() => document.activeElement?.closest("#helpbox-wrapper") != null, null, { timeout: 5000 });
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.querySelector("#helpbox-wrapper").classList.contains("open"), null, { timeout: 5000 });
  f = await focused(page);
  assert.deepEqual([f.tag, f.label, f.in_panel], ["button", "Help", false]);
  assertNoProblems(page);
});

test("focus ring: 2 px accent outline 2 px out on keyboard focus, none after a click (167)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "keyboard-167.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  for (let i = 0; i < 30; i++) {
    await page.keyboard.press("Tab");
    if (await page.evaluate(() => document.activeElement?.matches("button.toggle_export"))) break;
  }
  const ring = () => page.evaluate(() => {
    const button = document.querySelector("button.toggle_export");
    const probe = document.createElement("span");
    probe.style.color = "var(--ember-accent)";
    document.body.append(probe);
    const accent = getComputedStyle(probe).color;
    probe.remove();
    const s = getComputedStyle(button);
    return { focused: document.activeElement === button, style: s.outlineStyle, width: s.outlineWidth, color: s.outlineColor, offset: s.outlineOffset, accent };
  });
  const keyboard = await ring();
  assert.ok(keyboard.focused, "Tab reaches the Export button");
  assert.deepEqual(
    [keyboard.style, keyboard.width, keyboard.color, keyboard.offset],
    ["solid", "2px", keyboard.accent, "2px"]);

  // Opens the menu, then closes it; the menu hands focus back to the button.
  await page.locator("button.toggle_export").click();
  await page.waitForSelector("[role=menu]", { timeout: 5000 });
  await page.locator("button.toggle_export").click();
  await page.waitForSelector("[role=menu]", { state: "detached", timeout: 5000 });
  const mouse = await ring();
  assert.ok(mouse.focused, "the button keeps focus after the click");
  assert.equal(mouse.style, "none");
  assertNoProblems(page);
});

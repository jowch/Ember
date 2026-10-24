// ui-3-tests.md, piece 6a (ui-3-plan.md): the geometry, gutter, syntax
// colours, "+" buttons and cell menu of the Cells and Insert5 boards.
// Split from cells.test.mjs (#417).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, codeSelector } from "../browser.mjs";

const rect = (page, sel) => page.locator(sel).evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
});
// Several rects in one round trip, so a scroll between reads can't skew
// their differences.
const rects = (page, sels) => page.evaluate((sels) => Object.fromEntries(Object.entries(sels).map(([k, sel]) => {
  const r = document.querySelector(sel).getBoundingClientRect();
  return [k, { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }];
})), sels);
const near = (actual, expected, what) => assert.ok(Math.abs(actual - expected) < 0.6, `${what}: ${actual}, expected ${expected}`);

// A theme token as the browser computes it, for comparing with a computed
// background.
const tokenColor = (page, name) => page.evaluate((name) => {
  const probe = document.createElement("div");
  probe.style.backgroundColor = `var(${name})`;
  document.body.append(probe);
  const color = getComputedStyle(probe).backgroundColor;
  probe.remove();
  return color;
}, name);

// Geometry from the Cells and Insert5 boards (ui-3.md "Cell anatomy",
// "Run button", "Cell menu", "Adding cells").


test("geometry: 26px between cells; a one-line code box is 7px 12px around 13px/1.65 text, after a 34px gutter", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-box.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  // The static copy a cell shows before its editor loads is a .cm-editor
  // too, with the same layout (#375), and the real editor replaces it
  // between two reads, so wait for the real one (#398).
  await page.waitForSelector(`${cellSelector("A")} .cm-editor:not(.cm-ssr-fake)`);

  const { a, b, box, gutters } = await rects(page, {
    a: cellSelector("A"), b: cellSelector("B"), box: `${cellSelector("A")} .cm-editor:not(.cm-ssr-fake)`, gutters: `${cellSelector("A")} .cm-editor:not(.cm-ssr-fake) .cm-gutters`,
  });
  near(b.top - a.bottom, 26, "gap between A and B");
  near(box.height, 7 + 13 * 1.65 + 7, "one-line code box height");
  near(gutters.width, 34, "gutter width");

  const content = await page.locator(`${cellSelector("A")} .cm-editor:not(.cm-ssr-fake) .cm-content`).evaluate((el) => {
    const cs = getComputedStyle(el);
    const range = document.createRange();
    range.selectNodeContents(el.querySelector(".cm-line"));
    const gutterRight = el.closest(".cm-editor").querySelector(".cm-gutters").getBoundingClientRect().right;
    return { padding: cs.padding, fontSize: cs.fontSize, lineHeight: cs.lineHeight, textGap: range.getBoundingClientRect().left - gutterRight };
  });
  assert.equal(content.padding, "7px 12px");
  assert.equal(content.fontSize, "13px");
  assert.equal(content.lineHeight, "21.45px");
  near(content.textGap, 12, "code text starts 12px right of the gutter");

  assertNoProblems(page);
});

test("gutter: every code cell shows its line numbers, focused or not, 12px faint and 10px from the code", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-gutter.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator(cellSelector("W")).scrollIntoViewIfNeeded();
  const gutter = `${cellSelector("W")} .cm-gutter.cm-lineNumbers`;
  await page.waitForFunction((sel) => document.querySelectorAll(`${sel} .cm-gutterElement`).length >= 6, gutter);
  const faint = await tokenColor(page, "--ember-faint");
  const numbers = await page.locator(`${gutter} .cm-gutterElement`).evaluateAll((els) => els
    .filter((el) => el.textContent !== "" && el.style.visibility !== "hidden")
    .map((el) => {
      const s = getComputedStyle(el);
      const range = document.createRange();
      range.selectNodeContents(el);
      return {
        text: el.textContent,
        color: s.color,
        fontSize: s.fontSize,
        after: getComputedStyle(el, "::after").content,
        rightGap: el.closest(".cm-gutters").getBoundingClientRect().right - range.getBoundingClientRect().right,
      };
    }));
  assert.deepEqual(numbers.map((n) => n.text), ["1", "2", "3", "4", "5"]);
  for (const n of numbers) {
    assert.equal(n.color, faint, `line ${n.text} in the faint colour`);
    assert.equal(n.fontSize, "12px");
    assert.equal(n.after, "none", `line ${n.text} has no dot`);
    near(n.rightGap, 10, `line ${n.text} ends 10px left of the code`);
  }
  assert.equal(await page.locator(cellSelector("W")).evaluate((el) => el.contains(document.activeElement)), false, "W is not focused");

  assertNoProblems(page);
});

test("syntax: the Cells board's token colours in light and dark, nothing bold or italic", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-syntax.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ colorScheme: "light" });
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator(cellSelector("W")).scrollIntoViewIfNeeded();
  await page.waitForSelector(`${cellSelector("W")} .cm-editor:not(.cm-ssr-fake)`);

  const tokens = (id) => page.locator(codeSelector(id)).evaluate((el) =>
    [...el.querySelectorAll(".cm-line span")].filter((s) => s.children.length === 0 && s.textContent.trim() !== "").map((s) => {
      const c = getComputedStyle(s);
      return { text: s.textContent, color: c.color, weight: c.fontWeight, style: c.fontStyle };
    }));
  const check = async (theme) => {
    const fn = await tokenColor(page, "--ember-syn-fn");
    const kw = await tokenColor(page, "--ember-syn-kw");
    const str = await tokenColor(page, "--ember-syn-str");
    const num = await tokenColor(page, "--ember-syn-num");
    const text = await tokenColor(page, "--ember-text");
    const f = await tokens("F");
    const w = await tokens("W");
    const colour = (list, text_, n = 0) => list.filter((tk) => tk.text === text_)[n]?.color;
    assert.equal(colour(f, "f"), fn, `${theme}: an assigned name in the function colour`);
    assert.equal(colour(f, "function"), kw, `${theme}: a keyword`);
    assert.equal(colour(f, "lm"), fn, `${theme}: a call`);
    assert.equal(colour(f, "data"), text, `${theme}: an argument name is plain`);
    assert.equal(colour(f, "mpg"), text, `${theme}: a variable is plain`);
    assert.equal(colour(w, "message"), fn, `${theme}: a call`);
    assert.equal(colour(w, '"Reading"'), str, `${theme}: a string`);
    assert.equal(colour(w, "1"), num, `${theme}: a number`);
    for (const tk of [...f, ...w]) {
      assert.equal(tk.weight, "400", `${theme}: ${tk.text} is not bold`);
      assert.equal(tk.style, "normal", `${theme}: ${tk.text} is not italic`);
    }
  };
  await check("light");
  await page.emulateMedia({ colorScheme: "dark" });
  await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "dark");
  await check("dark");

  assertNoProblems(page);
});

test("geometry: the run button sits on the code box's top-left corner and gives way to the \"+\" above it", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-run.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // A has no output, so its code box starts at the cell's top, right under
  // the gap's "+".
  await page.hover(codeSelector("A"));
  const run = page.locator(`${cellSelector("A")} button.ember-run`);
  await page.waitForFunction((el) => getComputedStyle(el).opacity === "1", await run.elementHandle());
  const { box, button } = await rects(page, { box: `${cellSelector("A")} .cm-editor`, button: `${cellSelector("A")} button.ember-run` });
  near(button.left - box.left, -15, "run button left");
  near(button.top - box.top, -13, "run button top");

  const strip = await rect(page, `${cellSelector("A")} button.add_cell.before`);
  await page.mouse.move(strip.left + 300, strip.top + strip.height / 2);
  const circle = `${cellSelector("A")} button.add_cell.before > span`;
  await page.waitForFunction((sel) => getComputedStyle(document.querySelector(sel)).opacity === "1", circle);
  await page.waitForFunction((el) => getComputedStyle(el).opacity === "0", await run.elementHandle());

  // Insert5: the circle is centred on the gap, its left edge 11px left of the rail.
  // The circle's lower half is where the run button would be: it must be
  // the "+" that takes a click there.
  const { c, rail, gap, hit } = await page.evaluate(([circle, railSel, stripSel]) => {
    const c = document.querySelector(circle).getBoundingClientRect();
    const strip = document.querySelector(stripSel).getBoundingClientRect();
    const hit = document.elementFromPoint(c.left + c.width / 2, c.bottom - 3)?.closest("button")?.className ?? null;
    return { c: c.toJSON(), rail: document.querySelector(railSel).getBoundingClientRect().toJSON(), gap: strip.top + strip.height / 2, hit };
  }, [circle, `${cellSelector("A")} > pluto-trafficlight`, `${cellSelector("A")} button.add_cell.before`]);
  near(c.left - rail.left, -11, "circle left");
  near(c.top + c.height / 2, gap, "circle centre");
  assert.equal(hit, "add_cell before");

  assertNoProblems(page);
});

test('"+": each gap\'s live button is the lower cell\'s .before, and the last cell\'s .after below it (Endeavor)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-plus.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const ids = await page.evaluate(() => [...document.querySelectorAll("pluto-cell")].map((c) => c.id));
  for (const id of ids) {
    assert.equal(await page.locator(`${cellSelector(id)} > button.add_cell.before`).count(), 1, `${id} keeps .before`);
    assert.equal(await page.locator(`${cellSelector(id)} > button.add_cell.after`).count(), 1, `${id} keeps .after`);
  }

  // Who takes a click `dx` right of `upper`'s left edge: halfway down the
  // gap to `lower`, or `dy` below `upper` when there is no `lower`.
  const owner = (upper, lower, dx, dy) => page.evaluate(([upper, lower, dx, dy]) => {
    const above = document.querySelector(upper).getBoundingClientRect();
    const y = lower == null ? above.bottom + dy : (above.bottom + document.querySelector(lower).getBoundingClientRect().top) / 2;
    const b = document.elementFromPoint(above.left + dx, y)?.closest("button.add_cell");
    return b ? `${b.closest("pluto-cell").id} ${b.className}` : null;
  }, [upper, lower, dx, dy]);

  // elementFromPoint only sees the viewport.
  const show = (id) => page.locator(cellSelector(id)).evaluate((el) => el.scrollIntoView({ block: "center" }));
  for (let i = 1; i < ids.length; i++) {
    await show(ids[i]);
    assert.equal(await owner(cellSelector(ids[i - 1]), cellSelector(ids[i]), 300, 0), `${ids[i]} add_cell before`, `gap above ${ids[i]}`);
  }
  const last = ids[ids.length - 1];
  await show(last);
  assert.equal(await owner(cellSelector(last), null, 300, 13), `${last} add_cell after`, "below the last cell");

  assertNoProblems(page);
});

test("cell menu: the ⋯ is in pluto-input after the code, on the code box even under an error, and opens on a folded cell", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-menu-place.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForSelector(`${cellSelector("ERR")}.errored`);

  assert.equal(await page.locator("pluto-cell > button.input_context_menu").count(), 0);
  assert.equal(await page.locator("pluto-cell > pluto-input > button.input_context_menu").count(), await page.locator("pluto-cell").count());
  const order = await page.locator(`${cellSelector("A")} > pluto-input`).evaluate((input) =>
    [...input.children].map((c) => c.matches(".cm-editor") ? "code" : c.matches("button.ember-run") ? "run" : c.matches("button.input_context_menu") ? "menu" : null).filter(Boolean));
  assert.deepEqual(order, ["code", "run", "menu"], "Tab reaches the code first, then run, then ⋯");

  await page.hover(codeSelector("ERR"));
  const { box, more, output } = await rects(page, {
    box: `${cellSelector("ERR")} .cm-editor`,
    more: `${cellSelector("ERR")} button.input_context_menu`,
    output: `${cellSelector("ERR")} > pluto-output`,
  });
  near(box.right - more.right, 6, "⋯ right inset");
  near(more.top - box.top, 5, "⋯ top inset");
  assert.ok(more.top >= output.bottom, "the ⋯ is below the error output, not over it");

  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  await page.locator(`${cellSelector("B")} button.hide_code`).click();
  await page.waitForSelector(`${cellSelector("B")}.code_folded:not(.show_input)`);
  assert.equal(await page.locator(codeSelector("B", "")).isVisible(), false, "the folded cell's code is hidden");

  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  const showItem = page.locator(`${cellSelector("B")} button.hide_code`);
  assert.equal(await showItem.innerText(), "Show code");
  await showItem.click();
  await page.waitForFunction((sel) => !document.querySelector(sel).classList.contains("code_folded"), cellSelector("B"));
  await page.locator(codeSelector("B", "")).waitFor({ state: "visible" });

  assertNoProblems(page);
});

test("cell menu: on a cell at the bottom of the window it opens upwards, so every item is on screen; elsewhere downwards", async (t) => {
  const notebook = tempNotebook("many-cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-menu-flip.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 900, height: 700 });
  await openNotebook(page, server.origin, server.secret, notebook);

  // The first cell whose code box is wholly in view.
  const first = await page.evaluate(() => [...document.querySelectorAll("pluto-cell")].find((c) => {
    const r = c.querySelector("pluto-input").getBoundingClientRect();
    return r.top >= 0 && r.bottom <= innerHeight;
  }).id);
  const open = async (id) => {
    // The code box, not the whole cell: the cell's middle can be below the
    // window, and hovering there would scroll it.
    await page.hover(`${cellSelector(id)} pluto-input`);
    const before = (await rects(page, { more: `${cellSelector(id)} button.input_context_menu` })).more;
    await page.locator(`${cellSelector(id)} button.input_context_menu`).click();
    // Measured where it settles: the menu rises 4 px as it opens (#538).
    await page.locator(`${cellSelector(id)} div.input_context_menu[role="menu"]`).evaluate((el) => Promise.all(el.getAnimations().map((a) => a.finished)));
    return {
      before,
      ...await rects(page, {
        menu: `${cellSelector(id)} div.input_context_menu[role="menu"]`,
        more: `${cellSelector(id)} button.input_context_menu`,
      }),
    };
  };

  // A one-line cell whose code box ends at the bottom of the window. Where
  // cells land on their own depends on font metrics and on off-screen cells
  // swapping their stand-in for the real editor (#373), so this one is put
  // there: scrolled to the bottom until its real editor is in and it stays
  // put for a frame.
  const low = "C10";
  await page.waitForFunction((sel) => {
    const input = document.querySelector(`${sel} pluto-input`);
    input.scrollIntoView({ block: "end" });
    const bottom = input.getBoundingClientRect().bottom;
    const still = window.__low_bottom === bottom;
    window.__low_bottom = bottom;
    return still && Math.abs(bottom - innerHeight) < 1 && input.querySelector(".cm-editor:not(.cm-ssr-fake)") != null;
  }, cellSelector(low), { polling: "raf" });
  const bottom = await open(low);
  assert.ok(700 - bottom.before.bottom < 3 + bottom.menu.height, `the ⋯ ended at ${bottom.before.bottom} before the menu opened, so the menu fit below it and this cell can't show the flip`);
  assert.ok(bottom.menu.bottom <= 700, `menu ends at ${bottom.menu.bottom}, below the 700px window`);
  near(bottom.more.top - bottom.menu.bottom, 3, "3px above the ⋯");
  await page.keyboard.press("Escape");
  await page.evaluate(() => scrollTo(0, 0));

  const top = await open(first);
  near(top.menu.top - top.more.bottom, 3, "3px below the ⋯");
  await page.keyboard.press("Escape");

  // Too short a window for either way: it stays below, and the page scrolls.
  await page.setViewportSize({ width: 900, height: 200 });
  const short = await open(first);
  near(short.menu.top - short.more.bottom, 3, "3px below the ⋯ in a 200px window");
  await page.keyboard.press("Escape");

  assertNoProblems(page);
});

test("cell menu: text-only one-line items with a right-aligned key hint, panel and line colours, a 6px-radius trigger that stays on while open", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-menu-look.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("A"));
  const trigger = page.locator(`${cellSelector("A")} button.input_context_menu`);
  assert.equal(await trigger.evaluate((el) => getComputedStyle(el).borderRadius), "6px");
  await trigger.click();
  assert.match(await trigger.getAttribute("class"), /\bon\b/);

  const menu = page.locator(`${cellSelector("A")} div.input_context_menu[role="menu"]`);
  const colours = await menu.evaluate((el) => {
    const probe = document.createElement("div");
    probe.style.cssText = "border-top: 1px solid var(--ember-line); background: var(--ember-panel)";
    document.body.append(probe);
    const want = getComputedStyle(probe);
    const got = getComputedStyle(el);
    const r = { border: [got.borderTopColor, want.borderTopColor], background: [got.backgroundColor, want.backgroundColor] };
    probe.remove();
    return r;
  });
  assert.equal(colours.border[0], colours.border[1], "menu border is --ember-line");
  assert.equal(colours.background[0], colours.background[1], "menu background is --ember-panel");

  assert.equal(await menu.locator(".ctx_icon, svg, img").count(), 0, "no icons in the items");

  const moveUp = menu.locator("button.move_up");
  const item = await moveUp.evaluate((el) => {
    const cs = getComputedStyle(el);
    const key = el.querySelector(".ember-menuitem-key");
    const kr = key.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    return {
      direction: cs.flexDirection, padding: cs.padding, gap: cs.gap, height: r.height,
      key: key.textContent, keySize: getComputedStyle(key).fontSize, keyRightInset: r.right - kr.right,
      keyMiddle: kr.top + kr.height / 2 - (r.top + r.height / 2),
    };
  });
  assert.equal(item.direction, "row");
  assert.equal(item.padding, "7px 10px");
  assert.equal(item.gap, "10px");
  near(item.height, 7 + 13 * 1.65 + 7, "item height (Cells board)");
  assert.match(item.key, /^(Alt|⌥) ↑$/);
  assert.equal(item.keySize, "11.5px");
  near(item.keyRightInset, 10, "key hint is right-aligned");
  near(item.keyMiddle, 0, "key hint on the label's line");
  assert.equal(await moveUp.evaluate((el) => el.firstChild.textContent.trim()), "Move up");

  // The header's ⋯ menu keeps its stacked title-over-description items.
  const header = await page.evaluate(() => {
    const b = document.createElement("button");
    b.className = "ember-menuitem";
    document.body.append(b);
    const cs = getComputedStyle(b);
    const r = { direction: cs.flexDirection, padding: cs.padding };
    b.remove();
    return r;
  });
  assert.deepEqual(header, { direction: "column", padding: "8px 10px" });

  await page.keyboard.press("Escape");
  await page.waitForFunction((el) => !el.classList.contains("on"), await trigger.elementHandle());

  assertNoProblems(page);
});

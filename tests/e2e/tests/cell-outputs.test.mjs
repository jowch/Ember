// ui-3-tests.md, piece 6a (ui-3-plan.md): errors, disabled states,
// outputs, console text, figures and text cells. Split from
// cells.test.mjs (#417).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, runCell, cellSelector } from "../browser.mjs";

const rect = (page, sel) => page.locator(sel).evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
});
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
const computed = (page, sel, prop) => page.locator(sel).evaluate((el, prop) => getComputedStyle(el)[prop], prop);

test("errors: where it happened, a traceback outermost first, labelled by origin; the box joins the code (145)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-errors.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "F");
  await page.waitForFunction(
    () => window.editor_state.notebook.cell_results.F?.output?.last_run_timestamp > 0,
    null, { timeout: 30000 });
  for (const id of ["ERR", "TOP"]) {
    await runCell(page, id);
    await page.waitForSelector(`${cellSelector(id)}.errored jlerror.ember`, { timeout: 20000 });
  }

  const top = `${cellSelector("TOP")} jlerror`;
  assert.equal(await page.locator(`${top} > header > p:first-child`).innerText(), "boom");
  assert.equal(await page.locator(`${top} > header > p.ember-error-where`).innerText(), "Error · line 2");
  assert.equal(await page.locator(`${top} button`).count(), 0, "no traceback button for a top-level stop()");
  assert.equal(await page.locator(`${cellSelector("TOP")} ember-chip`).count(), 0, "no \"Not run yet\" chip on an errored cell");

  const err = `${cellSelector("ERR")} jlerror`;
  assert.equal(await page.locator(`${err} > header > p`).count(), 2, "jlerror > header holds the message, then where it happened");
  assert.equal(await page.locator(`${err} > header > p:first-child`).innerText(), "invalid type (list) for variable 'wt'");
  assert.equal(await page.locator(`${err} > header > p.ember-error-where`).innerText(), "Error in model.frame.default(…) · called from line 1");
  assert.equal(await page.locator(`${err} > header code`).innerText(), "model.frame.default(…)");

  const n = await page.evaluate(() => window.editor_state.notebook.cell_results.ERR.output.body.stacktrace.length);
  assert.ok(n >= 4, `the traceback has the notebook and stats calls (${n})`);
  const tbState = () => page.evaluate((sel) => {
    const button = document.querySelector(sel);
    const list = document.getElementById(button.getAttribute("aria-controls"));
    return { expanded: button.getAttribute("aria-expanded"), list: list?.matches("ol.ember-tb") ?? false, shown: list != null && list.getClientRects().length > 0, above: list != null && (button.compareDocumentPosition(list) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0 };
  }, `${err} button.ember-tb-toggle`);
  assert.deepEqual(await tbState(), { expanded: "false", list: true, shown: false, above: true }, "the traceback starts collapsed; the toggle controls the list below it");
  await page.getByRole("button", { name: `Show traceback (${n} calls)`, exact: true }).click();
  await page.getByRole("button", { name: "Hide traceback", exact: true }).waitFor({ timeout: 5000 });
  assert.deepEqual(await tbState(), { expanded: "true", list: true, shown: true, above: true }, "open: aria-expanded and the list shows");

  const frames = await page.locator(`${err} ol.ember-tb > li`).evaluateAll((lis) => lis.map((li) => ({
    n: li.querySelector(".ember-tb-n").innerText,
    call: li.querySelector("code").innerText,
    from: li.querySelector(".ember-tb-from").innerText,
    link: li.querySelector(".ember-tb-from a") != null,
    color: getComputedStyle(li).color,
  })));
  assert.equal(frames.length, n);
  const text = await tokenColor(page, "--ember-text");
  const faint = await tokenColor(page, "--ember-faint");
  assert.notEqual(text, faint);
  assert.deepEqual(frames[0], { n: "1", call: "g(bad)", from: "this cell, line 1", link: true, color: text }, "outermost first: the call in this cell");
  assert.match(frames[n - 1].call, /^model\.frame\.default\(/, "innermost last");
  const fd = frames.find((f) => f.call === "f(d)");
  assert.deepEqual(fd, { n: "2", call: "f(d)", from: "notebook", link: true, color: text }, "a function from another cell says notebook");
  const stats = frames.find((f) => f.from === "stats");
  assert.ok(stats, "a frame is labelled stats");
  assert.equal(stats.color, faint, "package calls are faint");

  await page.locator(`${err} ol.ember-tb > li:nth-child(2) .ember-tb-from a`).click();
  await page.waitForFunction((sel) => document.activeElement?.closest(sel) != null, cellSelector("F"), { timeout: 10000 });

  // Board Outputs4 / Cells: a red-tinted box flush with the rail and joined
  // to the code box, whose top-right corner goes square.
  // One evaluate, so all three come from the same frame: focusing F
  // smooth-scrolls the page, and separate reads can straddle a scroll step.
  const { box, cell, code } = await page.locator(cellSelector("ERR")).evaluate((el) => {
    const r = (e) => { const b = e.getBoundingClientRect(); return { left: b.left, top: b.top, right: b.right, bottom: b.bottom }; };
    return { box: r(el.querySelector("jlerror")), cell: r(el), code: r(el.querySelector(".cm-editor")) };
  });
  near(box.left, cell.left, "the box starts at the rail");
  near(box.right, code.right, "the box is as wide as the code box");
  near(code.top, box.bottom, "the box is joined to the code box");
  assert.equal(await computed(page, err, "backgroundColor"), await tokenColor(page, "--ember-err-bg"));
  assert.equal(await computed(page, err, "padding"), "10px 14px");
  assert.equal(await computed(page, err, "borderRadius"), "0px 6px 0px 0px");
  assert.equal(await computed(page, `${cellSelector("ERR")} .cm-editor:not(.cm-ssr-fake)`, "borderTopRightRadius"), "0px");
  const msg = `${err} > header > p:first-child`;
  assert.equal(await computed(page, msg, "fontSize"), "14px");
  assert.equal(await computed(page, msg, "fontWeight"), "600");
  assert.equal(await computed(page, msg, "color"), await tokenColor(page, "--ember-red"));
  assert.equal(await computed(page, `${err} > header > p.ember-error-where`, "color"), await tokenColor(page, "--ember-muted"));
  assert.equal(await computed(page, `${err} ol.ember-tb`, "borderTopStyle"), "dashed");

  assertNoProblems(page);
});

test("disabled states: A shows Disabled with no run button; B shows Depends on a disabled cell, and Go to it focuses A (149)", async (t) => {
  const notebook = tempNotebook("disabled.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-disabled-chips.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  const outputLeft = async (id) => (await rect(page, `${cellSelector(id)} > pluto-output pre`)).left - (await rect(page, cellSelector(id))).left;
  near(await outputLeft("B"), 12, "an output starts 12px right of the rail");

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  await page.locator(`${cellSelector("A")} button.disable_cell`).click();
  await page.waitForSelector(`${cellSelector("A")}.running_disabled`, { timeout: 15000 });

  assert.equal(await page.locator(`${cellSelector("A")} ember-chip`).innerText(), "Disabled");
  assert.equal(await page.locator(`${cellSelector("A")} button.ember-run`).count(), 0, "no run button on a disabled cell");
  assert.equal(await page.locator(`${cellSelector("A")} ember-chip`).count(), 1, "no \"Not run yet\" chip either");

  await page.waitForSelector(`${cellSelector("B")}.depends_on_disabled_cells`, { timeout: 15000 });
  const bChip = page.locator(`${cellSelector("B")} ember-chip`);
  assert.match(await bChip.innerText(), /Depends on a disabled cell\..*Go to it/s);
  assert.equal(await page.locator(`${cellSelector("B")} ember-chip`).count(), 1, "B has no \"Not run yet\" chip either");

  // Board Cells: the chip 12px from the rail, then the greyed output with
  // no wash behind it (the wash is the stale state's).
  assert.notEqual(await tokenColor(page, "--pluto-output-bg-color"), await tokenColor(page, "--ember-wash"));
  near(await outputLeft("B"), 12, "B's output to rail");
  for (const id of ["A", "B"]) {
    near((await rect(page, `${cellSelector(id)} > ember-chip`)).left - (await rect(page, cellSelector(id))).left, 12, `${id}'s chip to rail`);
    assert.equal(await computed(page, `${cellSelector(id)} > pluto-output`, "filter"), "grayscale(1)", `${id}'s output is greyed`);
    assert.equal(await computed(page, `${cellSelector(id)} > pluto-output`, "backgroundColor"), await tokenColor(page, "--pluto-output-bg-color"), `no wash behind ${id}'s output`);
    assert.equal(await page.locator(cellSelector(id)).evaluate((el) => getComputedStyle(el, "::before").content), "none", `no wash layer on ${id}`);
  }

  await bChip.locator("a").click();
  await page.waitForFunction(
    (sel) => document.activeElement?.closest(sel) != null,
    cellSelector("A"), { timeout: 10000 });

  assertNoProblems(page);
});

test("outputs: a table's size, types, NA cells and Show more; a list tree; printed text with no box (146)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const rich = tempNotebook("rich.R");
  const server = await startServer([notebook, rich], { logFile: path.join(artifactsDir(), "cells-outputs.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  for (const id of ["NA", "VEC"]) await runCell(page, id);

  const na = cellSelector("NA");
  await page.waitForSelector(`${na} table.pluto-table`, { timeout: 30000 });
  assert.equal(await page.locator(`${na} th.ember-table-size`).innerText(), "2 rows × 2 columns");
  assert.deepEqual(await page.locator(`${na} tr.schema-types th`).allInnerTexts(), ["", "dbl", "chr"]);
  assert.deepEqual(await page.locator(`${na} td.na`).allInnerTexts(), ["NA", "NA"]);
  assert.equal(await computed(page, `${na} td.na >> nth=0`, "color"), await tokenColor(page, "--ember-faint"));
  assert.equal(await computed(page, `${na} tbody tr:first-child td >> nth=0`, "color"), await tokenColor(page, "--ember-text"));
  assert.equal(await page.locator(`${na} button.ember-show-more`).count(), 0, "no Show more for a table shown whole");

  const vec = cellSelector("VEC");
  await page.waitForSelector(`${vec} pluto-tree.ember-tree`, { timeout: 30000 });
  const root = page.locator(vec).getByRole("button", { name: "list of 3", exact: true });
  assert.equal(await root.getAttribute("aria-expanded"), "true", "the root starts open");
  const sub = page.locator(vec).getByRole("button", { name: "sub list of 1", exact: true });
  assert.equal(await sub.getAttribute("aria-expanded"), "false", "a nested list starts collapsed");
  const long = page.locator(`${vec} .ember-tree-row`).filter({ has: page.locator(".ember-tree-key", { hasText: /^long$/ }) });
  assert.equal(await long.locator(".ember-tree-value").innerText(), "1 2 3 4 5 6 7 8 9 10 … int, 100 values");
  assert.equal(await long.locator(".ember-vector-count").innerText(), "int, 100 values");
  await sub.click();
  assert.equal(await sub.getAttribute("aria-expanded"), "true");
  assert.deepEqual(await page.locator(`${vec} pluto-tree.ember-tree pluto-tree.ember-tree > .ember-tree-items > .ember-tree-row`).allInnerTexts(), ["c\nx"]);
  await root.click();
  assert.equal(await page.locator(`${vec} .ember-tree-items`).count(), 0, "the root collapses");

  await openNotebook(page, server.origin, server.secret, rich);
  for (const id of ["DF", "TBL", "FIT"]) await runCell(page, id);
  const tbl = cellSelector("TBL");
  await page.waitForSelector(`${tbl} table.pluto-table`, { timeout: 30000 });
  assert.equal(await page.locator(`${tbl} th.ember-table-size`).innerText(), "32 rows × 11 columns");
  assert.equal(await page.locator(`${tbl} table.pluto-table tbody tr`).count(), 10, "no in-table \"more\" row");
  assert.equal(await page.locator(`${tbl} tr.schema-names th`).count(), 9, "the size cell and 8 columns, no in-table \"more\" column");
  await page.locator(tbl).getByRole("button", { name: "Show 3 more columns", exact: true }).waitFor();
  await page.locator(tbl).getByRole("button", { name: "Show 22 more rows", exact: true }).click();
  // The worker adds 60 rows per click; mtcars has 32.
  await page.waitForFunction(
    (sel) => document.querySelectorAll(`${sel} table.pluto-table tbody tr`).length === 32,
    tbl, { timeout: 10000 });
  assert.equal(await page.locator(`${tbl} button.ember-show-more`).allInnerTexts().then((x) => x.join("|")), "Show 3 more columns");

  const fit = `${cellSelector("FIT")} pluto-output pre`;
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("Coefficients"), fit, { timeout: 20000 });
  assert.equal(await computed(page, fit, "backgroundColor"), "rgba(0, 0, 0, 0)");
  assert.equal(await computed(page, fit, "paddingLeft"), "0px");

  assertNoProblems(page);
});

test("console: a muted message, a warning with its call, and ANSI colours from the theme (147)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-console.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ colorScheme: "light" });
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "W");
  const logs = `${cellSelector("W")} pluto-logs`;
  await page.waitForSelector(`${logs} ember-log.stdout`, { timeout: 30000 });

  assert.deepEqual(
    await page.locator(`${logs} > ember-log`).evaluateAll((els) => els.map((el) => [el.className, el.innerText])),
    [["message", "Reading"], ["warning", "Warning in h(): careful"], ["stdout", "ok grey"]]);
  assert.equal(await computed(page, `${logs} > ember-log.message`, "color"), await tokenColor(page, "--ember-muted"));
  assert.equal(await computed(page, `${logs} > ember-log.stdout`, "color"), await tokenColor(page, "--ember-text"));
  assert.equal(await page.locator(`${logs} > ember-log.warning > b`).innerText(), "Warning");
  assert.equal(await page.locator(`${logs} > ember-log.warning > code`).innerText(), "h()");
  assert.equal(await computed(page, `${logs} > ember-log.warning`, "backgroundColor"), await tokenColor(page, "--ember-due-bg"));
  assert.equal(await computed(page, `${logs} > ember-log.warning > b`, "color"), await tokenColor(page, "--ember-warn-text"));

  // \033[38;5;246m is a 256-colour code: it gets a base colour's class, not an inline rgb().
  assert.equal(await page.locator(`${logs} span.ansi-bright-black-fg`).innerText(), "grey");
  assert.equal(await page.locator(`${logs} [style*="rgb("]`).count(), 0);
  const green = `${logs} span.ansi-green-fg`;
  assert.equal(await computed(page, green, "color"), "rgb(43, 122, 75)");

  await page.emulateMedia({ colorScheme: "dark" });
  await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "dark", null, { timeout: 5000 });
  assert.equal(await computed(page, green, "color"), "rgb(134, 209, 159)");

  assertNoProblems(page);
});

test("console: a long print shows its first 60 and last 20 lines, and \"Show more\" reveals 500 at a time (350)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-long-console.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const logs = `${cellSelector("W")} pluto-logs`;
  const marker = `${logs} > pluto-log-truncated`;
  await setCellCode(page, "W", 'message("start")\ncat(sprintf("line %d\\n", 1:1000), sep = "")');
  await page.keyboard.press("Shift+Enter");
  await page.waitForSelector(marker, { timeout: 30000 });

  // Every line on the page, in order: a message is one, a stdout block one per line.
  const shown = () => page.locator(logs).evaluate((el) => [...el.children].flatMap((child) =>
    child.localName === "pluto-log-truncated" ? ["--"] : child.innerText.split("\n")));
  const lines = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => `line ${from + i}`);

  // 1001 lines: the message, then 1000 of stdout.
  assert.deepEqual(await shown(), ["start", ...lines(1, 59), "--", ...lines(981, 1000)]);
  assert.equal(await page.locator(`${marker}`).innerText().then((s) => s.replace(/\s+/g, " ").trim()), "921 lines not shown Show 500 more");
  assert.equal(await page.locator(`${logs} > ember-log.stdout`).count(), 2, "the stdout either side of the cut stays one block each");

  await page.locator(marker).getByRole("button", { name: "Show 500 more", exact: true }).click();
  await page.locator(marker).getByRole("button", { name: "Show 421 more", exact: true }).waitFor();
  assert.deepEqual(await shown(), ["start", ...lines(1, 559), "--", ...lines(981, 1000)]);
  await page.locator(marker).getByRole("button", { name: "Show 421 more", exact: true }).click();
  await page.waitForSelector(marker, { state: "detached", timeout: 5000 });
  assert.deepEqual(await shown(), ["start", ...lines(1, 1000)]);
  assert.equal(await page.locator(`${logs} > ember-log.stdout`).count(), 1);

  // A rerun starts the cut over.
  await runCell(page, "W");
  await page.waitForSelector(marker, { timeout: 30000 });
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("921 lines not shown"), marker, { timeout: 10000 });

  assertNoProblems(page);
});

test("console: one very long line shows its first 10,000 characters, and a long message is cut by its lines (350)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-long-line.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const logs = `${cellSelector("W")} pluto-logs`;
  // cat() doesn't wrap: 25,000 characters on one line, then a 200-line message.
  await setCellCode(page, "W", 'cat(strrep("x", 25000))\nmessage(paste("m", 1:200, collapse = "\\n"))');
  await page.keyboard.press("Shift+Enter");
  await page.waitForSelector(`${logs} > pluto-log-truncated`, { timeout: 30000 });

  const stdout = await page.locator(`${logs} > ember-log.stdout`).innerText();
  assert.equal(stdout, `${"x".repeat(10000)}… 15,000 more characters not shown`);
  const messages = await page.locator(`${logs} > ember-log.message`).allInnerTexts();
  assert.equal(messages.length, 2, "the message on either side of the cut");
  assert.deepEqual(messages[0].split("\n"), Array.from({ length: 59 }, (_, i) => `m ${i + 1}`));
  assert.deepEqual(messages[1].split("\n"), Array.from({ length: 20 }, (_, i) => `m ${i + 181}`));
  assert.match(await page.locator(`${logs} > pluto-log-truncated`).innerText(), /^121 lines not shown/);

  assertNoProblems(page);
});

test("figures: no border, background or filter in either theme; at most the column wide; a default plot is 708px, 14px above the code; fig-width 4 is 384px (148)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-figures.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ colorScheme: "light" });
  await openNotebook(page, server.origin, server.secret, notebook);
  const img = `${cellSelector("PLT")} pluto-output img`;
  await runCell(page, "PLT");
  await page.waitForFunction((sel) => document.querySelector(sel)?.naturalWidth > 0, img, { timeout: 30000 });

  // Outputs4/Cells: `.out` is padded 2px 0 0 12px, so a default plot fills
  // the 708px the Cells board draws its figure at, 14px above the code box;
  // a printed output sits 12px above it and an empty one adds nothing.
  const underOutput = (id) => page.evaluate((sel) => {
    const cell = document.querySelector(sel);
    const out = cell.querySelector(":scope > pluto-output");
    const last = [...out.querySelectorAll("img, pre")].pop() ?? out;
    const code = cell.querySelector("pluto-input .cm-editor").getBoundingClientRect();
    return {
      padding: getComputedStyle(out).padding,
      width: out.querySelector("img")?.getBoundingClientRect().width ?? null,
      gap: Math.round((code.top - last.getBoundingClientRect().bottom) * 10) / 10,
    };
  }, cellSelector(id));
  assert.deepEqual(await underOutput("PLT"), { padding: "2px 0px 0px 12px", width: 708, gap: 14 }, "a default plot");
  for (const id of ["S", "DF", "FIT"]) await runCell(page, id);
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("Coefficients"), `${cellSelector("FIT")} > pluto-output`, { timeout: 30000 }).catch(() => {});
  assert.deepEqual(await underOutput("FIT"), { padding: "2px 0px 0px 12px", width: null, gap: 12 }, "printed text");
  // S only defines a function, so its output is empty.
  const empty = await underOutput("S");
  assert.equal(empty.gap, 0, "an empty output adds no gap above the code");

  const look = () => page.locator(img).evaluate((el) => {
    const s = getComputedStyle(el);
    const output = el.closest("pluto-output");
    const os = getComputedStyle(output);
    const column = output.clientWidth - parseFloat(os.paddingLeft) - parseFloat(os.paddingRight);
    return {
      border: [s.borderTopWidth, s.borderRightWidth, s.borderBottomWidth, s.borderLeftWidth].join(" "),
      radius: s.borderTopLeftRadius,
      background: [s.backgroundColor, s.backgroundImage].join(" "),
      filter: s.filter,
      boxShadow: s.boxShadow,
      fits: el.getBoundingClientRect().width <= column + 0.5,
    };
  });
  const plain = { border: "0px 0px 0px 0px", radius: "0px", background: "rgba(0, 0, 0, 0) none", filter: "none", boxShadow: "none", fits: true };
  assert.deepEqual(await look(), plain, "light");
  await page.emulateMedia({ colorScheme: "dark" });
  await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "dark", null, { timeout: 5000 });
  assert.deepEqual(await look(), plain, "dark");
  await page.setViewportSize({ width: 390, height: 800 });
  assert.equal((await look()).fits, true, "fits a phone-width column");
  await page.setViewportSize({ width: 1280, height: 800 });

  await setCellCode(page, "FIG", "#| fig-width: 4\n#| fig-height: 3\nplot(1:10)");
  await page.keyboard.press("Shift+Enter");
  const fig = `${cellSelector("FIG")} pluto-output img`;
  await page.waitForFunction(
    (sel) => { const el = document.querySelector(sel); return el?.naturalWidth > 0 && Math.abs(el.getBoundingClientRect().width - 384) < 1; },
    fig, { timeout: 30000 }).catch(() => {});
  assert.equal(Math.round(await page.locator(fig).evaluate((el) => el.getBoundingClientRect().width)), 384);

  assertNoProblems(page);
});

test("text cells: serif text with tinted values that copy as plain text; click or Tab + Enter opens the source, #' continues, Esc closes it and selects the cell, Shift + Enter closes it and focuses the text (150)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-text.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ colorScheme: "light" });
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "A");
  const cell = cellSelector("TXT");
  const out = `${cell} > pluto-output`;
  const editor = `${cell} pluto-input .cm-editor`;
  // A's first run starts R and puts its output above TXT, moving TXT down:
  // a drag measured before that lands can start beside the paragraph and
  // select nothing (#120). So the test starts once A's run is done.
  await page.waitForFunction((sel) => {
    const a = document.querySelector(sel);
    return a != null && !a.matches(".running, .queued") && (a.querySelector(":scope > pluto-output")?.innerText.trim() ?? "") !== "";
  }, cellSelector("A"), { timeout: 30000 });
  const isOpen = () => page.locator(cell).evaluate((el) => el.classList.contains("show_input"));
  // A click opens the source once the double-click interval has passed, so
  // "didn't open" is only known after that.
  const staysClosed = async (what) => {
    await page.waitForTimeout(700);
    assert.equal(await isOpen(), false, what);
  };
  const closes = async (what) => {
    await page.waitForFunction((sel) => !document.querySelector(sel).classList.contains("show_input"), cell, { timeout: 5000 }).catch(() => {});
    assert.equal(await isOpen(), false, what);
  };
  const textFocused = () => page.evaluate((sel) => document.activeElement === document.querySelector(sel), out);
  await page.locator(cell).scrollIntoViewIfNeeded();
  assert.equal(await isOpen(), false, "a text cell starts with its source hidden");

  // Keep the link's navigation from leaving the page; the cell still sees the click.
  await page.evaluate(() => document.addEventListener("click", (e) => { if (e.target.closest("a")) e.preventDefault(); }, true));
  await page.locator(`${out} a`).click();
  await staysClosed("clicking a link doesn't open the source");

  const p = await page.locator(`${out} p`).boundingBox();
  await page.mouse.move(p.x + 2, p.y + p.height / 2);
  await page.mouse.down();
  await page.mouse.move(p.x + 120, p.y + p.height / 2, { steps: 5 });
  await page.mouse.up();
  const p_after = await page.locator(`${out} p`).boundingBox();
  assert.ok((await page.evaluate(() => getSelection().toString())).length > 5,
    `the drag selected text (the paragraph's box before the drag: ${JSON.stringify(p)}, after: ${JSON.stringify(p_after)})`);
  await staysClosed("selecting text by dragging doesn't open the source");

  // A click inside the dragged selection would keep it until mouseup.
  await page.evaluate(() => getSelection().removeAllRanges());
  await page.locator(`${out} p`).dblclick({ position: { x: 12, y: p.height / 2 } });
  await staysClosed("double-clicking a word doesn't open the source");
  assert.equal(await page.evaluate(() => getSelection().toString().trim()), "One", "the double click selected the word");

  await page.locator(`${out} h2`).click();
  await page.locator(editor).waitFor({ state: "visible", timeout: 5000 });
  assert.equal(await page.locator(`${editor} .cm-ember-md-h`).innerText(), "## Results");
  assert.equal(await page.locator(`${cell} .preview_hidden_code_info`).isVisible(), false, "no hidden-code note on an open text cell");
  assert.equal(await computed(page, `${editor} .cm-ember-md-h`, "color"), await tokenColor(page, "--ember-syn-kw"));
  assert.equal(await computed(page, `${editor} .cm-ember-r`, "color"), await tokenColor(page, "--ember-ansi-cyan"));
  const source = () => page.locator(editor).evaluate((el) => el.CodeMirror.getValue().split("\n"));
  const original = await source();

  // Enter at the start of a #' line is a plain Enter.
  await page.waitForFunction((sel) => document.activeElement?.closest(sel) != null, editor, { timeout: 5000 });
  await page.keyboard.press(process.platform === "darwin" ? "Meta+ArrowUp" : "Control+Home");
  await page.keyboard.press("Enter");
  assert.deepEqual((await source()).slice(0, 2), ["", "#' ## Results"], "Enter in column 0 adds an empty line above, with no #'");
  await page.keyboard.press(process.platform === "darwin" ? "Meta+z" : "Control+z");
  assert.deepEqual(await source(), original, "undone");

  await page.keyboard.press("Escape");
  await closes("Esc closes the unchanged source");
  await page.waitForFunction((sel) => document.activeElement === document.querySelector(sel), cell, { timeout: 5000 }).catch(() => {});
  assert.deepEqual(await page.evaluate((sel) => [document.activeElement === document.querySelector(sel), window.editor_state.selected_cells], cell),
    [true, ["TXT"]], "after Esc, the cell is focused and selected");

  // Keyboard: Tab reaches the text, Enter opens its source.
  await page.locator(`${cell} > button.add_cell.before`).evaluate((el) => el.focus());
  for (let i = 0; i < 5 && !(await textFocused()); i++) await page.keyboard.press("Tab");
  assert.equal(await textFocused(), true, "Tab reaches the text");
  assert.deepEqual(await page.locator(out).evaluate((el) => [el.tabIndex, el.getAttribute("role"), el.getAttribute("aria-label")]),
    [0, "group", "Text cell. Press Enter to edit its source."]);
  await page.keyboard.press("Enter");
  await page.locator(editor).waitFor({ state: "visible", timeout: 5000 });
  await page.waitForFunction((sel) => document.activeElement?.closest(sel) != null, editor, { timeout: 5000 });
  assert.deepEqual(await source(), original, "Enter on the text opens it without typing a newline");
  await page.keyboard.press("Escape");
  await closes("Esc closes it again");

  await page.locator(`${out} p`).click({ position: { x: 5, y: 5 } });
  await page.locator(editor).waitFor({ state: "visible", timeout: 5000 });
  await page.waitForFunction((sel) => document.activeElement?.closest(sel) != null, editor, { timeout: 5000 });
  const before = await source();
  await page.keyboard.press("End");
  await page.keyboard.press("Enter");
  const after = await source();
  assert.equal(after.length, before.length + 1, "Enter adds one line");
  assert.deepEqual(after.filter((line) => line === "#' "), ["#' "], "the new line starts with #' and a space");
  await page.keyboard.press("Shift+Enter");
  await closes("Shift + Enter closes the source");
  assert.equal(await textFocused(), true, "after Shift + Enter, focus is on the text");

  const inline = `${out} span.ember-inline`;
  await page.waitForFunction((sel) => document.querySelector(sel)?.textContent === "2", inline, { timeout: 30000 });
  assert.match(await computed(page, `${out} h2`, "fontFamily"), /^"Source Serif 4"/);
  assert.equal(await computed(page, inline, "backgroundColor"), await tokenColor(page, "--ember-accent-bg"));
  const pseudo = await page.locator(inline).evaluate((el) => [getComputedStyle(el, "::before").content, getComputedStyle(el, "::after").content]);
  assert.deepEqual(pseudo, ["none", "none"]);
  const copied = await page.locator(`${out} p`).evaluate((p) => {
    const range = document.createRange();
    range.selectNodeContents(p);
    getSelection().removeAllRanges();
    getSelection().addRange(range);
    return getSelection().toString();
  });
  assert.equal(copied, "One more than x is 2, as the docs say.");

  assertNoProblems(page);
});

test("text cells: keys pressed as the source opens, before it has drawn, aren't undone by the opening cursor (#120)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-text-early-keys.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const cell = cellSelector("TXT");
  const out = `${cell} > pluto-output`;
  const editor = `${cell} pluto-input .cm-editor`;
  const source = () => page.locator(editor).evaluate((el) => el.CodeMirror.getValue().split("\n"));
  await page.locator(cell).scrollIntoViewIfNeeded();

  // Hold animation frames, the way a slow or busy machine delays them, so
  // the keys below land after the editor has focus but before its next
  // frames. Opening the source then put the cursor at the end of the text
  // two frames later, on top of wherever the keys had moved it, so Enter
  // landed at the end (#120: macOS CI, cells.test.mjs "Enter in column 0").
  await page.evaluate(() => {
    const held = new Map();
    let next = 1;
    const real = { request: window.requestAnimationFrame.bind(window), cancel: window.cancelAnimationFrame.bind(window) };
    window.requestAnimationFrame = (cb) => { held.set(next, cb); return next++; };
    window.cancelAnimationFrame = (id) => held.delete(id);
    window.__release_frames = () => {
      window.requestAnimationFrame = real.request;
      window.cancelAnimationFrame = real.cancel;
      for (const cb of held.values()) real.request(cb);
      held.clear();
    };
  });
  await page.locator(`${out} h2`).click();
  await page.locator(editor).waitFor({ state: "visible", timeout: 5000 });
  await page.waitForFunction((sel) => document.activeElement?.closest(sel) != null, editor, { timeout: 5000 });
  await page.keyboard.press(process.platform === "darwin" ? "Meta+ArrowUp" : "Control+Home");
  // The frames come between the two keys: two for the deferred cursor,
  // and one more to be sure it ran.
  await page.evaluate(() => window.__release_frames());
  await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(done)))));
  await page.keyboard.press("Enter");
  assert.deepEqual((await source()).slice(0, 2), ["", "#' ## Results"], "Enter in column 0 adds an empty line above");

  assertNoProblems(page);
});

// The scripted half of a UI audit (.claude/skills/ui-audit): walks the
// journeys a person takes through Ember, saves a screenshot at each step,
// and measures what screenshots can't show (layout shift, time to add a
// cell, keyboard focus, layout problems, console errors). It doesn't
// judge: an agent or a person reads the screenshots and notes.json
// against the skill's rubric.
//
// Usage (from tests/e2e, after `npm ci`):
//   node audit.mjs [--out DIR] [--only A,B,...]
//
// Journeys: A first open and run all; B add, type, run, cell menu, delete,
// undo; C header, side panel, menus and dialogs at 1440, 900 and 600 px;
// D keyboard only; E dark mode; F a 30-cell notebook with plots (cost of
// adding a cell and typing). A journey that throws is recorded as a
// finding and the rest still run.
//
// Writes DIR/<journey>-<step>.png and DIR/notes.json. Like run.mjs it
// installs this checkout into a temp library first, unless EMBER_E2E_LIB
// names one. EMBER_BROWSER=webkit runs it in WebKit.

import path from "node:path";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { ensureLib } from "./install.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const { values } = parseArgs({
  options: {
    out: { type: "string", default: path.join(HERE, "test-results", "audit") },
    only: { type: "string" },
  },
});
const only = values.only ? new Set(values.only.split(",")) : null;
const OUT = values.out;
mkdirSync(OUT, { recursive: true });

const { lib, owned } = ensureLib();
process.env.EMBER_E2E_LIB = lib;
const { startServer, tempNotebook } = await import("./server.mjs");
const { launchBrowser, newPage, openNotebook, cellSelector } = await import("./browser.mjs");
const { pageProblems } = await import("./layout-check.mjs");

const notes = { browser: process.env.EMBER_BROWSER ?? "chromium", started: new Date().toISOString(), journeys: {} };
let current;
const note = (key, value) => { notes.journeys[current][key] = value; };
const shot = async (page, step, full = false) => {
  const file = `${current}-${step}.png`;
  await page.screenshot({ path: path.join(OUT, file), fullPage: full });
  (notes.journeys[current].screenshots ??= []).push(file);
};

/** Start collecting layout shifts (CLS, from the Layout Instability API)
 * and long tasks on `page`; read them back with `measured(page)`. Not
 * every engine has both APIs; a missing one reads as null. */
async function measure(page) {
  await page.evaluate(() => {
    window.__audit = { cls: null, shifts: [], long: null };
    try {
      window.__audit.cls = 0;
      new PerformanceObserver((list) => {
        for (const e of list.getEntries()) {
          if (e.hadRecentInput) continue;
          window.__audit.cls += e.value;
          window.__audit.shifts.push({ value: Number(e.value.toFixed(4)), at: Math.round(e.startTime),
            moved: (e.sources ?? []).map((s) => s.node?.nodeName?.toLowerCase() + (s.node?.className ? "." + String(s.node.className).split(" ")[0] : "")).slice(0, 3) });
        }
      }).observe({ type: "layout-shift" });
    } catch { window.__audit.cls = null; }
    try {
      window.__audit.long = [];
      new PerformanceObserver((list) => { for (const e of list.getEntries()) window.__audit.long.push(Math.round(e.duration)); }).observe({ type: "longtask" });
    } catch { window.__audit.long = null; }
  });
}
const measured = (page) => page.evaluate(() => ({ ...window.__audit, cls: window.__audit.cls == null ? null : Number(window.__audit.cls.toFixed(3)) }));

async function waitIdle(page, timeout = 60000) {
  await page.waitForFunction(() => document.querySelectorAll("pluto-cell.running, pluto-cell.queued").length === 0, null, { timeout });
}

async function journey(name, fn) {
  if (only && !only.has(name)) return;
  current = name;
  notes.journeys[name] = {};
  try { await fn(); } catch (e) { note("error", String(e.message ?? e).split("\n")[0]); }
}

const browser = await launchBrowser();
const servers = [];
async function open(fixture, width = 900) {
  const nb = tempNotebook(fixture);
  const server = await startServer([nb], { logFile: path.join(OUT, `server-${current}.log`) });
  servers.push(server);
  const page = await newPage(browser);
  await page.setViewportSize({ width, height: 900 });
  await openNotebook(page, server.origin, server.secret, nb);
  return { page, server, nb };
}
async function runAll(page) {
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(() => !document.querySelector("#ember-safe-preview"), null, { timeout: 30000 });
  await page.waitForTimeout(500);
  await waitIdle(page, 120000);
  await page.waitForTimeout(800);
}
const finish = (page) => note("console", page.problems.slice());

try {
  await journey("A", async () => {
    const { page } = await open("ui-sweep.R");
    await shot(page, "1-safe-preview");
    note("problems-preview", await pageProblems(page));
    await measure(page);
    await runAll(page);
    note("run-all", await measured(page));
    await shot(page, "2-ran");
    await shot(page, "3-ran-full", true);
    note("problems-ran", await pageProblems(page));
    finish(page);
  });

  await journey("B", async () => {
    const { page } = await open("ui-sweep.R");
    await runAll(page);
    await measure(page);
    const before = await page.locator("pluto-cell").count();
    // The "+" between B and WIDE (WIDE's "before" button sits on top of
    // B's "after" one).
    await page.locator(cellSelector("WIDE")).hover();
    const add = page.locator(`${cellSelector("WIDE")} button.add_cell.before`);
    const t0 = Date.now();
    await add.click();
    await page.waitForFunction((n) => document.querySelectorAll("pluto-cell").length === n + 1, before, { timeout: 5000 });
    note("add-ms", Date.now() - t0);
    note("focus-after-add", await page.evaluate(() => document.activeElement?.closest("pluto-cell") ? "new cell's editor" : document.activeElement?.tagName));
    await page.keyboard.type("y <- x + 100", { delay: 5 });
    await shot(page, "1-typed");
    await page.keyboard.press("Shift+Enter");
    await waitIdle(page);
    await page.waitForTimeout(500);
    await shot(page, "2-ran");
    const id = await page.evaluate(() => { const c = [...document.querySelectorAll("pluto-cell")]; return c[c.findIndex((x) => x.id === "B") + 1].id; });
    await page.locator(cellSelector(id)).hover();
    await page.locator(`${cellSelector(id)} button.input_context_menu`).click();
    await page.waitForTimeout(300);
    await shot(page, "3-cell-menu");
    note("cell-menu", await page.locator(`${cellSelector(id)} [role=menuitem]`).allInnerTexts());
    note("problems-menu-open", await pageProblems(page));
    await page.locator(`${cellSelector(id)} [role=menuitem]`).filter({ hasText: "Delete" }).click();
    await page.waitForTimeout(500);
    await shot(page, "4-after-delete");
    const undo = page.locator("nav#undo_delete:not(.hidden) a");
    note("undo-offered", await undo.count() > 0);
    if (await undo.count()) { await undo.first().click(); await page.waitForTimeout(800); await shot(page, "5-after-undo"); }
    note("add-run-delete", await measured(page));
    finish(page);
  });

  await journey("C", async () => {
    const { page } = await open("ui-sweep.R", 1440);
    await runAll(page);
    for (const width of [1440, 900, 600]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.waitForTimeout(400);
      await shot(page, `${width}-1-header`);
      const icons = await page.locator("header#pluto-nav button").evaluateAll((bs) =>
        bs.filter((b) => b.getClientRects().length).map((b) => b.getAttribute("aria-label") || b.innerText.trim()));
      note(`${width}-header-buttons`, icons);
      for (const tab of ["Variables", "Packages", "Help", "Status"]) {
        await page.evaluate((t) => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: t.toLowerCase() })), tab);
        await page.waitForTimeout(600);
        await shot(page, `${width}-2-panel-${tab}`);
        const problems = await pageProblems(page);
        if (problems.length) note(`${width}-problems-panel-${tab}`, problems);
      }
      const more = page.locator('header#pluto-nav button[aria-label="More"]');
      await more.click();
      await page.waitForTimeout(300);
      await shot(page, `${width}-3-more-menu`);
      note(`${width}-more-menu`, await page.locator("[role=menu] [role=menuitem]").allInnerTexts());
      const problems = await pageProblems(page);
      if (problems.length) note(`${width}-problems-more-menu`, problems);
      await page.keyboard.press("Escape");
      for (const [label, sel] of [["Settings", "dialog.psettings[open]"], ["Keyboard shortcuts", "dialog.ember-shortcuts[open]"]]) {
        await more.click();
        await page.locator("[role=menu] [role=menuitem]").filter({ hasText: label }).click();
        await page.waitForSelector(sel, { timeout: 5000 });
        await page.waitForTimeout(300);
        await shot(page, `${width}-4-${label.replace(/ /g, "-").toLowerCase()}`);
        const p = await pageProblems(page);
        if (p.length) note(`${width}-problems-${label}`, p);
        await page.keyboard.press("Escape");
        await page.waitForTimeout(200);
      }
    }
    finish(page);
  });

  await journey("D", async () => {
    const { page } = await open("ui-sweep.R", 1200);
    await runAll(page);
    await page.evaluate(() => { document.activeElement?.blur(); window.scrollTo(0, 0); });
    const stops = [];
    for (let i = 0; i < 25; i++) {
      await page.keyboard.press("Tab");
      stops.push(await page.evaluate(() => {
        const el = document.activeElement;
        if (!el || el === document.body) return { at: "body" };
        const cs = getComputedStyle(el);
        const ring = (cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0) || cs.boxShadow !== "none";
        const r = el.getBoundingClientRect();
        return { at: `${el.tagName.toLowerCase()} ${(el.getAttribute("aria-label") || el.innerText || "").trim().slice(0, 30)}`,
          cell: el.closest("pluto-cell")?.id ?? null, ring, onScreen: r.bottom > 0 && r.top < innerHeight };
      }));
    }
    note("tab-stops", stops);
    await shot(page, "1-after-tabbing");
    // Leave an editor the way CodeMirror says: Escape, then Tab.
    await page.keyboard.press("Escape");
    await page.keyboard.press("Tab");
    note("after-escape-tab", await page.evaluate(() => document.activeElement?.closest("pluto-cell")?.id ?? document.activeElement?.tagName));
    note("cells-edited-by-tabbing", await page.evaluate(() => [...document.querySelectorAll("pluto-cell.code_differs")].map((c) => c.id)));
    finish(page);
  });

  await journey("E", async () => {
    const { page } = await open("ui-sweep.R");
    await page.emulateMedia({ colorScheme: "dark" });
    await runAll(page);
    await shot(page, "1-dark", true);
    const { AxeBuilder } = await import("@axe-core/playwright");
    const axe = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa"]).analyze();
    note("axe-dark", axe.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, example: v.nodes[0]?.target?.join(" ") })));
    finish(page);
  });

  await journey("F", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "ember-audit-"));
    const cells = [];
    for (let i = 1; i <= 30; i++) {
      const id = `P${String(i).padStart(2, "0")}`;
      const code = i % 3 === 0 ? `plot(rnorm(200), main = "plot ${i}")` : i % 3 === 1 ? `v${i} <- rnorm(${i * 10})` : `summary(v${i - 1})`;
      cells.push({ id, code });
    }
    const file = path.join(dir, "big.R");
    writeFileSync(file, "### An Ember notebook ###\n# /// environment\n# ember_version = \"0.0.0.9000\"\n# r_version = \"4.6.1\"\n# snapshot = \"2026-01-01\"\n# ///\n\n" +
      cells.map((c) => `# %% id=${c.id}\n${c.code}\n`).join("\n") +
      "\n# /// cell order\n" + cells.map((c) => `# ${c.id}\n`).join("") + "# ///\n");
    const server = await startServer([file], { logFile: path.join(OUT, "server-F.log") });
    servers.push(server);
    const page = await newPage(browser);
    await page.setViewportSize({ width: 900, height: 900 });
    const t0 = Date.now();
    await openNotebook(page, server.origin, server.secret, file);
    note("open-ms", Date.now() - t0);
    const t1 = Date.now();
    await runAll(page);
    note("run-all-ms", Date.now() - t1);
    await measure(page);
    const n = await page.locator("pluto-cell").count();
    await page.locator(cellSelector("P16")).hover();
    const t2 = Date.now();
    await page.locator(`${cellSelector("P16")} button.add_cell.before`).click();
    await page.waitForFunction((n) => document.querySelectorAll("pluto-cell").length === n + 1, n);
    note("add-cell-ms", Date.now() - t2);
    const t3 = Date.now();
    await page.keyboard.type("z <- 1:100", { delay: 0 });
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    note("type-10-chars-ms", Date.now() - t3);
    note("perf", await measured(page));
    await shot(page, "1-big-notebook");
    finish(page);
  });
} finally {
  await browser.close();
  for (const s of servers) s.stop();
  notes.finished = new Date().toISOString();
  writeFileSync(path.join(OUT, "notes.json"), JSON.stringify(notes, null, 2));
  console.log(`audit: ${path.join(OUT, "notes.json")}`);
  for (const [name, j] of Object.entries(notes.journeys)) if (j.error) console.log(`journey ${name} failed: ${j.error}`);
  if (owned) rmSync(lib, { recursive: true, force: true });
}

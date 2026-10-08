// Run states that pass quickly never paint (common/useSettled.js): a
// queued or running rail, "Not run yet", "Run N not run" and "Running i of
// n" show only once they have lasted 250 ms. Also: a new cell is never
// queued, and a text cell run with Cmd+Enter ends idle.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

const RUN_AND_ADD = process.platform === "darwin" ? "Meta+Enter" : "Control+Enter";

/** Records, on every animation frame until stopFrames(), what each cell
 * and the header show. */
const startFrames = (page) =>
  page.evaluate(() => {
    window.__frames = [];
    window.__stop_frames = false;
    window.__frames_start = performance.now();
    const tick = () => {
      const header_not_run = [...document.querySelectorAll("nav#at_the_top .ember-btn")].find((b) => /not run/.test(b.innerText));
      window.__frames.push({
        t: performance.now() - window.__frames_start,
        status: document.querySelector("#ember-r-status")?.innerText ?? "",
        not_run: header_not_run == null ? 0 : Number(header_not_run.innerText.match(/\d+/)?.[0] ?? 0),
        cells: [...document.querySelectorAll("pluto-notebook > pluto-cell")].map((c) => ({
          id: c.id,
          rail: c.dataset.rail,
          label: c.getAttribute("aria-label"),
          chip: c.querySelector(":scope > ember-chip")?.innerText ?? null,
          busy: c.querySelector("button.ember-run.busy") != null,
          output: c.querySelector(":scope > pluto-output")?.innerText ?? "",
        })),
      });
      if (!window.__stop_frames) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });

const stopFrames = (page) =>
  page.evaluate(() => {
    window.__stop_frames = true;
    return window.__frames;
  });

const newCellAfter = (page, id) =>
  page.evaluate((id) => {
    const cells = [...document.querySelectorAll("pluto-notebook > pluto-cell")];
    return cells[cells.findIndex((c) => c.id === id) + 1]?.id ?? null;
  }, id);

test("transitions: a run never paints queued, running or \"Not run yet\" in its first 250 ms or once done; a new cell is never queued", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "transitions-first-run.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // R started and warm, so the timed run below is only the run itself.
  await runCell(page, "B");
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("55"), cellSelector("B") + " pluto-output", { timeout: 30000 });
  await page.waitForFunction(() => document.querySelector("#ember-r-status")?.innerText === "R ready", null, { timeout: 10000 });

  // Cmd+Enter on unchanged code only adds a cell below.
  await startFrames(page);
  await page.keyboard.press(RUN_AND_ADD);
  await page.waitForFunction(() => document.querySelectorAll("pluto-notebook > pluto-cell").length === 7, null, { timeout: 10000 });
  const id = await newCellAfter(page, "B");
  await page.waitForTimeout(400);
  const adding = await stopFrames(page);
  const queuedWhileAdding = adding.flatMap((f) => f.cells.filter((c) => c.rail === "queued" || /queued/.test(c.label)).map((c) => `${c.id} at ${f.t.toFixed(0)} ms`));
  assert.deepEqual(queuedWhileAdding, [], "no cell shows queued while a cell is added");

  // A passing state shows only once it has lasted SETTLE_MS, counted from
  // when the page first saw it, which is after the key press and so after
  // the frames' clock started. So no frame before SETTLE_MS may show one,
  // however long the run takes, and none after the result arrives. Only a
  // run slower than SETTLE_MS may rightly show queued in between, so the
  // checks below cover the whole run when it is fast and those two windows
  // when it is not: a slow runner weakens the test instead of failing it.
  // Try for a fast run a few times first.
  const SETTLE_MS = 250;
  const baseline_not_run = adding.at(-1).not_run;
  let frames = null;
  let ran_in = null;
  for (const [attempt, code, result] of [[1, "1 + 1", "2"], [2, "1 + 2", "3"], [3, "1 + 3", "4"]]) {
    await page.locator(`${cellSelector(id)} .cm-content`).click();
    await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
    await page.keyboard.type(code, { delay: 2 });
    await startFrames(page);
    await page.keyboard.press("Shift+Enter");
    await page.waitForFunction(
      ([sel, result]) => document.querySelector(sel)?.innerText.includes(result),
      [cellSelector(id) + " > pluto-output", result], { timeout: 15000 });
    await page.waitForTimeout(400);
    frames = await stopFrames(page);
    ran_in = frames.find((f) => f.cells.find((c) => c.id === id)?.output.includes(result))?.t;
    assert.ok(ran_in != null, `attempt ${attempt}: a recorded frame shows the result`);
    if (ran_in < SETTLE_MS - 1) break;
    t.diagnostic(`attempt ${attempt} ran in ${ran_in.toFixed(0)} ms; retrying`);
  }
  if (ran_in >= SETTLE_MS - 1) {
    t.diagnostic(`every run took ${SETTLE_MS} ms or more (last ${ran_in.toFixed(0)} ms); checking only before ${SETTLE_MS - 1} ms and after the result`);
  }

  const mine = frames
    .filter((f) => f.t < SETTLE_MS - 1 || f.t >= ran_in)
    .map((f) => ({ ...f, cell: f.cells.find((c) => c.id === id) }));
  const at = (f) => `at ${f.t.toFixed(0)} ms`;
  const together = mine.filter((f) => f.cell.chip === "Not run yet" && f.cell.rail === "queued");
  assert.deepEqual(together.map(at), [], "\"Not run yet\" and queued never show together");
  assert.deepEqual(mine.filter((f) => f.cell.chip === "Not run yet").map(at), [], "no \"Not run yet\" chip");
  assert.deepEqual(mine.filter((f) => f.cell.rail === "queued" || f.cell.rail === "run").map((f) => `${f.cell.rail} ${at(f)}`), [], "no queued or running rail");
  assert.deepEqual(mine.filter((f) => /queued|running|not run yet/.test(f.cell.label)).map((f) => `${f.cell.label} ${at(f)}`), [], "the cell's name never says queued, running or not run");
  assert.deepEqual(mine.filter((f) => f.cell.busy).map(at), [], "the run button never turns into Stop");
  assert.deepEqual(mine.filter((f) => f.status !== "R ready").map((f) => `${f.status} ${at(f)}`), [], "the header says R ready throughout");
  assert.deepEqual(mine.filter((f) => f.not_run > baseline_not_run).map((f) => `${f.not_run} ${at(f)}`), [], "\"Run N not run\" never counts the running cell");

  assertNoProblems(page);
});

test("transitions: a text cell run with Cmd+Enter ends idle, not queued", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "transitions-text.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator(`${cellSelector("B")} .cm-content`).click();
  await page.keyboard.press(RUN_AND_ADD);
  await page.waitForFunction(() => document.querySelectorAll("pluto-notebook > pluto-cell").length === 7, null, { timeout: 10000 });
  const id = await newCellAfter(page, "B");
  await page.locator(`${cellSelector(id)} .cm-content`).click();
  await page.keyboard.type("#' Hello", { delay: 2 });
  await page.keyboard.press(RUN_AND_ADD);
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("Hello"), `${cellSelector(id)} > pluto-output`, { timeout: 15000 });
  await page.waitForTimeout(1000);

  const state = await page.locator(cellSelector(id)).evaluate((el) => ({
    rail: el.dataset.rail,
    label: el.getAttribute("aria-label"),
    queued: el.classList.contains("queued"),
  }));
  assert.deepEqual(state, { rail: "idle", label: "Text cell", queued: false });

  assertNoProblems(page);
});

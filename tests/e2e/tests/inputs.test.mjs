// docs/inputs.md: a cell's inputs show above its output, and moving one
// sets its variable and reruns the cells that read it, not its own cell.
// emberui comes from a file:// repository built from inst/emberui, as the
// R tests' ui_repo() builds it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, tempDir, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector, waitIdle } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EMBERUI = path.join(HERE, "..", "..", "..", "inst", "emberui");

/** A CRAN-like file:// repository holding emberui, dated as the fixture's snapshot. */
const uiRepo = () => {
  const root = tempDir("ember-e2e-ui-repo-");
  const contrib = path.join(root, "2026-09-01", "src", "contrib");
  mkdirSync(contrib, { recursive: true });
  const rscript = process.env.EMBER_RSCRIPT ?? "Rscript";
  const r = path.basename(rscript) === rscript ? "R" : path.join(path.dirname(rscript), "R");
  const built = spawnSync(r, ["CMD", "build", "--no-manual", "--no-build-vignettes", EMBERUI], { cwd: contrib, encoding: "utf8" });
  assert.equal(built.status, 0, built.stderr);
  const indexed = spawnSync(rscript, ["-e", `tools::write_PACKAGES(${JSON.stringify(contrib)}, type = "source")`], { encoding: "utf8" });
  assert.equal(indexed.status, 0, indexed.stderr);
  return root;
};

/** Wait until cell `id` has run since `after` (a last_run_timestamp) and isn't running or queued: emberui's install comes first. */
const waitRan = (page, id, after = 0) =>
  page.waitForFunction(([id, after]) => {
    const r = window.editor_state?.notebook?.cell_results?.[id];
    return r != null && r.output.last_run_timestamp > after && !r.running && !r.queued;
  }, [id, after], { timeout: 120000 });
const lastRun = (page, id) => page.evaluate((id) => window.editor_state.notebook.cell_results[id].output.last_run_timestamp, id);

const output = (page, id) => page.locator(`${cellSelector(id)} pluto-output`).textContent();
const waitOutput = (page, id, re) =>
  page.waitForFunction(([sel, src]) => new RegExp(src).test(document.querySelector(sel)?.textContent ?? ""),
    [`${cellSelector(id)} pluto-output`, re.source], { timeout: 60000 });

test("inputs.R: an input on a cell's last line is its output widget, and moving it reruns its readers", async (t) => {
  const notebook = tempNotebook("inputs.R");
  const server = await startServer([notebook], {
    repos: { cran: `file://${uiRepo()}`, bioc_config: null },
    logFile: path.join(artifactsDir(), "inputs.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });
  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // emberui installs from the repository; running the reader runs the inputs' cells first.
  await runCell(page, "L");
  await waitRan(page, "L");
  await runCell(page, "B");
  await waitOutput(page, "B", /5 pearson TRUE Results 5 y/);
  for (const id of ["R", "X", "P"]) {
    await runCell(page, id);
    await waitRan(page, id);
  }

  // An input on the cell's last line is its output: the one widget in the output area, above the code.
  // An input that isn't the output is a read-only line below the code, with the note saying why.
  const placed = (id) => page.evaluate((sel) => {
    const cell = document.querySelector(sel);
    const code = cell.querySelector("pluto-input");
    return [...cell.querySelectorAll("ember-inputs")].map((el) => ({
      cls: el.className, n: el.querySelectorAll("ember-input").length,
      controls: el.querySelectorAll("input, select").length,
      before_code: !!(el.compareDocumentPosition(code) & Node.DOCUMENT_POSITION_FOLLOWING),
    }));
  }, cellSelector(id));
  assert.deepEqual(await placed("N"), [{ cls: "output", n: 1, controls: 1, before_code: true }]);
  assert.equal(await page.locator(`${cellSelector("N")} pluto-output`).count(), 0);
  assert.deepEqual(await placed("X"), [{ cls: "below", n: 2, controls: 0, before_code: false }]);
  assert.match(await output(page, "X"), /\[1\] 2/);
  const lines = page.locator(`${cellSelector("X")} ember-input`);
  assert.match(await lines.nth(0).textContent(), /q = 2 \(slider\).*Only the input on the cell's last line can be moved/);
  assert.match(await lines.nth(1).textContent(), /= 2 \(number\).*Assign this input to a name at the top of the cell/);

  // A plot drawn before the input isn't the output: it shows below the code, not lost.
  const plotBelow = await page.evaluate((sel) => {
    const cell = document.querySelector(sel);
    const out = cell.querySelector(":scope > pluto-output");
    return out != null && out.querySelector("img") != null &&
      !!(cell.querySelector("pluto-input").compareDocumentPosition(out) & Node.DOCUMENT_POSITION_FOLLOWING);
  }, cellSelector("P"));
  assert.equal(plotBelow, true);
  assert.deepEqual(await placed("P"), [{ cls: "output", n: 1, controls: 1, before_code: true }]);

  // The slider: B reruns with the new value; N doesn't rerun, and the slider is marked as off its default.
  const slider = page.locator(`${cellSelector("N")} input[type="range"]`);
  assert.equal(await slider.inputValue(), "5");
  await slider.fill("8");
  await waitOutput(page, "B", /8 pearson TRUE Results 5 y/);
  await page.locator(`${cellSelector("N")} ember-input.slider.changed`).waitFor();

  // The dropdown sends its choice, and B gets the element, not the label.
  await page.locator(`${cellSelector("M")} select`).selectOption({ label: "Spearman" });
  await waitOutput(page, "B", /8 spearman TRUE Results 5 y/);

  // The checkbox, and the text box (sent on Enter).
  await page.locator(`${cellSelector("CB")} input[type="checkbox"]`).uncheck();
  await waitOutput(page, "B", /8 spearman FALSE Results 5 y/);
  const text = page.locator(`${cellSelector("TX")} input[type="text"]`);
  await text.fill("Done");
  await text.press("Enter");
  await waitOutput(page, "B", /8 spearman FALSE Done 5 y/);

  // Radio groups in different cells are separate groups: each keeps its own pick.
  const radio = (id, k) => page.locator(`${cellSelector(id)} input[type="radio"]`).nth(k);
  assert.deepEqual([await radio("J", 0).isChecked(), await radio("J", 1).isChecked()], [false, true]);
  assert.deepEqual([await radio("R", 0).isChecked(), await radio("R", 1).isChecked()], [true, false]);
  await radio("J", 0).check();
  await waitOutput(page, "B", /8 spearman FALSE Done 5 x/);
  assert.equal(await radio("R", 0).isChecked(), true);

  // A number outside the input's limits stays in the box with what the input allows, and isn't sent.
  const number = page.locator(`${cellSelector("K")} input[type="number"]`);
  await number.fill("999");
  await number.press("Enter");
  const error = page.locator(`${cellSelector("K")} .ember-input-error`);
  await error.waitFor();
  assert.equal(await error.textContent(), "The value must be a whole number from 0 to 10.");
  assert.equal(await number.inputValue(), "999");
  await number.fill("3");
  await number.press("Enter");
  await waitOutput(page, "B", /8 spearman FALSE Done 3 x/);
  assert.equal(await error.count(), 0);
  // An integer input rounds first, as R does: 10.4 is 10, inside the limits.
  await number.fill("10.4");
  await number.press("Enter");
  await waitOutput(page, "B", /8 spearman FALSE Done 10 x/);
  assert.equal(await error.count(), 0);
  await number.fill("3");
  await number.press("Enter");
  await waitOutput(page, "B", /8 spearman FALSE Done 3 x/);

  // A drag: many values in a row, faster than the cells run. B ends at the last one.
  for (const v of ["2", "3", "4", "6", "7", "9", "10", "1"]) await slider.fill(v);
  await waitOutput(page, "B", /^\[1\] "1 spearman FALSE Done 3 x"/);
  await waitIdle(page);
  assert.equal(await slider.inputValue(), "1");
  assert.match(await output(page, "B"), /"1 spearman FALSE Done 3 x"/);

  // The input's own cell reruns: it keeps its value, so B's doesn't change.
  const ran = await lastRun(page, "N");
  await runCell(page, "N");
  await waitRan(page, "N", ran);
  await waitIdle(page);
  assert.equal(await slider.inputValue(), "1");
  assert.match(await output(page, "B"), /"1 spearman FALSE Done 3 x"/);

  assertNoProblems(page);
});

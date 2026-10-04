// Names, the run announcement and reduced motion, tests 160, 168 and 170
// of docs/ui-3-tests.md (piece 7f), and the axe audit, test 171.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, runCell, setCellCode } from "../browser.mjs";
import { AxeBuilder } from "@axe-core/playwright";

/** Every visible button, menu item and link inside `scope` whose name is
 * missing, or, for an icon-only one, whose aria-label isn't its title.
 * Controls with visible text may have a longer tooltip (the file name's is
 * the full path), so the title rule is for icons only. */
function unnamed(page, scope) {
  return page.evaluate((scope) => {
    const root = document.querySelector(scope);
    const name = (el) =>
      (el.getAttribute("aria-label") ??
        (el.getAttribute("aria-labelledby") ?? "").split(/\s+/).map((id) => document.getElementById(id)?.textContent ?? "").join(" ")).trim() ||
      el.textContent.trim() ||
      (el.getAttribute("title") ?? "").trim();
    return [...root.querySelectorAll("button, [role=menuitem], a")]
      .filter((el) => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden")
      .filter((el) => {
        if (name(el) === "") return true;
        const icon_only = el.textContent.trim() === "" && !el.hasAttribute("aria-labelledby");
        return icon_only && el.getAttribute("aria-label") !== el.getAttribute("title");
      })
      .map((el) => el.outerHTML.slice(0, 160));
  }, scope);
}

async function waitIdle(page) {
  await page.waitForFunction(() => {
    const nb = window.editor_state?.notebook;
    return nb?.process_status === "ready" && Object.values(nb.cell_results).every((r) => !r.running && !r.queued);
  }, null, { timeout: 30000 });
}

test("names: every visible control has a name, and an icon's name is its tooltip (160)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "a11y-160.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.waitForSelector(".ember-menu [role=menuitem]", { timeout: 5000 });
  assert.deepEqual(await unnamed(page, "body"), []);

  await page.getByRole("menuitem", { name: "Settings", exact: true }).click();
  await page.waitForSelector("dialog.psettings[open]", { timeout: 5000 });
  assert.deepEqual(await unnamed(page, "dialog.psettings[open]"), []);
  await page.getByRole("button", { name: "Done", exact: true }).click();
  await page.locator("dialog.psettings").waitFor({ state: "detached", timeout: 5000 });

  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.getByRole("menuitem", { name: "Keyboard shortcuts", exact: true }).click();
  await page.waitForSelector("dialog.ember-shortcuts[open]", { timeout: 5000 });
  assert.deepEqual(await unnamed(page, "dialog.ember-shortcuts[open]"), []);
  assertNoProblems(page);
});

test("cell names and one announcement per run (168)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "a11y-168.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const status = page.locator("#ember-run-status");
  assert.equal(await status.getAttribute("role"), "status");
  assert.equal(await page.locator("pluto-output[aria-live]").count(), 0, "outputs are not live regions");

  await runCell(page, "A");
  await waitIdle(page);
  await page.waitForFunction(() => document.querySelector("#ember-run-status").textContent.startsWith("Finished: "), null, { timeout: 5000 });

  await runCell(page, "B");
  await page.waitForFunction(() => document.querySelector("#ember-run-status").textContent === "Finished: 1 cell", null, { timeout: 30000 });

  await runCell(page, "ERR");
  await page.waitForFunction(() => document.querySelector("#ember-run-status").textContent === "A cell: error", null, { timeout: 30000 });

  await setCellCode(page, "ERR", 'fit <- stop("bad")');
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction(() => document.querySelector("#ember-run-status").textContent === "fit: error", null, { timeout: 30000 });

  const labels = await page.evaluate(() => Object.fromEntries(["A", "ERR", "MD"].map((id) => [id, document.getElementById(id).getAttribute("aria-label")])));
  assert.equal(labels.ERR, "Cell defining fit, error");
  assert.ok(labels.A.startsWith("Cell defining x"), labels.A);
  assert.equal(labels.MD, "Text cell");
  assert.equal(await page.locator(`${cellSelector("A")}`).getAttribute("role"), "group");
  assertNoProblems(page);
});

test("reduced motion: the running rail is still and the menu doesn't move (170)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "a11y-170.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "LOOP");
  await page.waitForSelector(`${cellSelector("LOOP")}.running`, { timeout: 30000 });
  const rail = () => page.locator(`${cellSelector("LOOP")} > pluto-trafficlight`).evaluate((el) => getComputedStyle(el).animationName);
  // The running look is held back 250 ms after the cell starts (useSettled).
  const deadline = Date.now() + 5000;
  while ((await rail()) !== "ember-rail-pulse" && Date.now() < deadline) await page.waitForTimeout(50);
  assert.equal(await rail(), "ember-rail-pulse", "the rail pulses without the preference");

  await page.emulateMedia({ reducedMotion: "reduce" });
  assert.equal(await rail(), "none");

  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.waitForSelector(".ember-menu [role=menuitem]", { timeout: 5000 });
  const motion = await page.evaluate(() =>
    [document.querySelector(".ember-menu"), ...document.querySelectorAll(".ember-menu *")]
      .map((el) => getComputedStyle(el))
      .filter((s) => s.animationName !== "none" || s.transitionDuration.split(",").some((d) => parseFloat(d) > 0))
      .length);
  assert.equal(motion, 0, "nothing in the menu animates or transitions");
  assertNoProblems(page);
});

/** axe's serious and critical findings on the page as it stands, one line
 * per rule with the selectors of the nodes it flagged, plus every
 * aria-describedby or aria-labelledby naming an id that isn't on the page
 * (axe only lists those as "needs review"). */
async function axeFindings(page, label) {
  const { violations } = await new AxeBuilder({ page }).analyze();
  const dangling = await page.evaluate(() =>
    [...document.querySelectorAll("[aria-describedby], [aria-labelledby]")].flatMap((el) =>
      ["aria-describedby", "aria-labelledby"]
        .flatMap((attr) => (el.getAttribute(attr) ?? "").split(/\s+/).filter((id) => id !== "" && document.getElementById(id) == null).map((id) => `${attr}="${id}"`))
        .map((ref) => `${el.tagName.toLowerCase()}.${[...el.classList].join(".")} ${ref}`)));
  return [
    ...violations
      .filter((v) => v.impact === "serious" || v.impact === "critical")
      .map((v) => `${label}: ${v.id} (${v.impact}): ${v.nodes.map((n) => n.target.join(" ")).join(" | ")}`),
    ...dangling.map((d) => `${label}: missing id: ${d}`),
  ];
}

/** Leave safe preview, which runs the notebook, and wait for the run to end. */
async function runAll(page) {
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(() => window.editor_state.notebook.cell_results.B?.output?.last_run_timestamp > 0, null, { timeout: 30000 });
  await waitIdle(page);
}

for (const scheme of ["light", "dark"]) {
  test(`axe finds nothing serious, ${scheme} (171)`, async (t) => {
    const basic = tempNotebook("basic.R");
    const cells = tempNotebook("cells.R");
    const server = await startServer([basic, cells], { logFile: path.join(artifactsDir(), `a11y-171-${scheme}.server.log`) });
    const browser = await launchBrowser();
    t.after(async () => { await browser.close(); server.stop(); });

    const page = await newPage(browser);
    await page.emulateMedia({ colorScheme: scheme });
    const findings = [];

    await openNotebook(page, server.origin, server.secret, basic);
    assert.equal(await page.evaluate(() => document.documentElement.getAttribute("data-theme")), scheme);
    await runAll(page);
    findings.push(...(await axeFindings(page, "basic.R")));

    await page.getByRole("button", { name: "More", exact: true }).click();
    await page.getByRole("menuitem", { name: "Settings", exact: true }).click();
    await page.waitForSelector("dialog.psettings[open]", { timeout: 5000 });
    findings.push(...(await axeFindings(page, "Settings")));
    await page.getByRole("button", { name: "Done", exact: true }).click();
    await page.locator("dialog.psettings").waitFor({ state: "detached", timeout: 5000 });

    await page.getByRole("button", { name: "More", exact: true }).click();
    await page.getByRole("menuitem", { name: "Keyboard shortcuts", exact: true }).click();
    await page.waitForSelector("dialog.ember-shortcuts[open]", { timeout: 5000 });
    findings.push(...(await axeFindings(page, "shortcuts")));

    await openNotebook(page, server.origin, server.secret, cells);
    await runAll(page);
    findings.push(...(await axeFindings(page, "cells.R")));

    await page.goto(server.url);
    await page.waitForSelector(".ember-start-row", { timeout: 10000 });
    findings.push(...(await axeFindings(page, "start page")));

    assert.deepEqual(findings, []);
    assertNoProblems(page);
  });
}

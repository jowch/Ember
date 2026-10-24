// Names, the run announcement and reduced motion, tests 160, 168 and 170
// of docs/ui-3-tests.md (piece 7f), and the axe audit, test 171.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, runCell, setCellCode, waitIdle } from "../browser.mjs";
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

/** From now on, every announcement #ember-run-status makes, in order, in
 * `window.ember_announcements`. The tracker clears the text before each
 * one, so a run whose words are the same as the last run's still counts:
 * waiting for the status to read some text can't tell the two apart. */
async function recordAnnouncements(page) {
  await page.evaluate(() => {
    const el = document.querySelector("#ember-run-status");
    window.ember_announcements = [];
    let last = el.textContent;
    new MutationObserver(() => {
      const now = el.textContent;
      if (now !== "" && now !== last) window.ember_announcements.push(now);
      last = now;
    }).observe(el, { childList: true, characterData: true, subtree: true });
  });
}

/** The `n`th announcement since recordAnnouncements(), once it is made. */
const announcement = (page, n) =>
  page.waitForFunction((n) => window.ember_announcements[n] ?? false, n).then((h) => h.jsonValue());

test("names: every visible control has a name, and an icon's name is its tooltip (160)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "a11y-160.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.waitForSelector(".ember-menu [role=menuitem]");
  assert.deepEqual(await unnamed(page, "body"), []);

  await page.getByRole("menuitem", { name: "Settings", exact: true }).click();
  await page.waitForSelector("dialog.psettings[open]");
  assert.deepEqual(await unnamed(page, "dialog.psettings[open]"), []);
  await page.getByRole("button", { name: "Done", exact: true }).click();
  await page.locator("dialog.psettings").waitFor({ state: "detached" });

  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.getByRole("menuitem", { name: "Keyboard shortcuts", exact: true }).click();
  await page.waitForSelector("dialog.ember-shortcuts[open]");
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

  await recordAnnouncements(page);

  // A's run says "Finished: 1 cell" too, so each step waits for its own
  // announcement, not for the words: B's step once passed on A's, and
  // ERR's run then started while B's was still going (#70).
  await runCell(page, "A");
  await waitIdle(page);
  assert.match(await announcement(page, 0), /^Finished: /);

  await runCell(page, "B");
  assert.equal(await announcement(page, 1), "Finished: 1 cell");

  await runCell(page, "ERR");
  assert.equal(await announcement(page, 2), "A cell: error");

  await setCellCode(page, "ERR", 'fit <- stop("bad")');
  await page.keyboard.press("Shift+Enter");
  assert.equal(await announcement(page, 3), "fit: error");
  assert.equal(await page.evaluate(() => window.ember_announcements.length), 4, "one announcement per run");

  const labels = await page.evaluate(() => Object.fromEntries(["A", "ERR", "MD"].map((id) => [id, document.getElementById(id).getAttribute("aria-label")])));
  assert.equal(labels.ERR, "Cell defining fit, error");
  assert.ok(labels.A.startsWith("Cell defining x"), labels.A);
  assert.equal(labels.MD, "Text cell");
  assert.equal(await page.locator(`${cellSelector("A")}`).getAttribute("role"), "group");
  assertNoProblems(page);
});

// #70: a run started while another is still going. Its cells show up only
// once its requests reach the server; here those are held back until the
// first run has ended and been announced, which is what a slow runner did
// by chance. The second run must still get its own announcement.
test("a run started while another is going is announced, even when its cells show up after that run ends (#70)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "a11y-overlap.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // Messages from the page to the server, held while `held` is a list.
  let held = null;
  let to_server = null;
  await page.routeWebSocket(/.*/, (ws) => {
    const srv = ws.connectToServer();
    to_server = srv;
    ws.onMessage((m) => (held == null ? srv.send(m) : held.push(m)));
    srv.onMessage((m) => ws.send(m));
  });
  await openNotebook(page, server.origin, server.secret, notebook);
  await recordAnnouncements(page);

  await runCell(page, "LOOP");
  await page.waitForFunction(() => document.querySelector('pluto-cell[id="LOOP"]')?.classList.contains("running"));
  await setCellCode(page, "ERR", 'fit <- stop("bad")');
  held = [];
  await page.keyboard.press("Shift+Enter");

  assert.equal(await announcement(page, 0), "Finished: 1 cell", "LOOP's run, once it ends");
  assert.ok(held.length > 0, "ERR's requests were held back");
  const release = held;
  held = null;
  for (const m of release) to_server.send(m);
  assert.equal(await announcement(page, 1), "fit: error", "ERR's run, started while LOOP's was going");
  assertNoProblems(page);
});

test("reduced motion: the running rail is still and menus, dialogs and the panel don't move (170)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "a11y-170.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "LOOP");
  await page.waitForSelector(`${cellSelector("LOOP")}.running`);
  const rail = () => page.locator(`${cellSelector("LOOP")} > pluto-trafficlight`).evaluate((el) => getComputedStyle(el).animationName);
  // The running look is held back 250 ms after the cell starts (useSettled).
  await page.waitForFunction((sel) => getComputedStyle(document.querySelector(sel)).animationName === "ember-rail-pulse",
    `${cellSelector("LOOP")} > pluto-trafficlight`);
  assert.equal(await rail(), "ember-rail-pulse", "the rail pulses without the preference");

  await page.emulateMedia({ reducedMotion: "reduce" });
  assert.equal(await rail(), "none");

  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.waitForSelector(".ember-menu [role=menuitem]");
  const motion = await page.evaluate(() =>
    [document.querySelector(".ember-menu"), ...document.querySelectorAll(".ember-menu *")]
      .map((el) => getComputedStyle(el))
      .filter((s) => s.animationName !== "none" || s.transitionDuration.split(",").some((d) => parseFloat(d) > 0))
      .length);
  assert.equal(motion, 0, "nothing in the menu animates or transitions");

  // Nor do the dialogs and the side panel, which rise and slide in
  // without the preference (#538).
  await page.getByRole("menuitem", { name: "Keyboard shortcuts", exact: true }).click();
  await page.waitForSelector("dialog.ember-shortcuts[open]");
  assert.deepEqual(await page.locator("dialog.ember-shortcuts[open]").evaluate((el) =>
    [getComputedStyle(el).animationName, getComputedStyle(el, "::backdrop").animationName]), ["none", "none"]);
  await page.keyboard.press("Escape");
  await page.locator("dialog.ember-shortcuts").waitFor({ state: "detached" });
  await page.locator('header#pluto-nav button[aria-label="Variables"]').click();
  await page.waitForSelector("#helpbox-wrapper.open");
  assert.equal(await page.locator("#helpbox-wrapper.open").evaluate((el) => getComputedStyle(el).animationName), "none");
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
  await page.waitForFunction(() => window.editor_state.notebook.cell_results.B?.output?.last_run_timestamp > 0);
  await waitIdle(page);
}

for (const scheme of ["light", "dark"]) {
  test(`axe finds nothing serious, ${scheme} (171)`, async (t) => {
    const basic = tempNotebook("basic.R");
    const cells = tempNotebook("cells.R");
    const sweep = tempNotebook("ui-sweep.R");
    const server = await startServer([basic, cells, sweep], { logFile: path.join(artifactsDir(), `a11y-171-${scheme}.server.log`) });
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
    await page.waitForSelector("dialog.psettings[open]");
    findings.push(...(await axeFindings(page, "Settings")));
    await page.getByRole("button", { name: "Done", exact: true }).click();
    await page.locator("dialog.psettings").waitFor({ state: "detached" });

    await page.getByRole("button", { name: "More", exact: true }).click();
    await page.getByRole("menuitem", { name: "Keyboard shortcuts", exact: true }).click();
    await page.waitForSelector("dialog.ember-shortcuts[open]");
    findings.push(...(await axeFindings(page, "shortcuts")));

    await openNotebook(page, server.origin, server.secret, cells);
    await runAll(page);
    findings.push(...(await axeFindings(page, "cells.R")));

    // One of each kind of output, a plot among them (#294).
    await openNotebook(page, server.origin, server.secret, sweep);
    await runAll(page);
    await page.waitForSelector(`${cellSelector("PLT")} pluto-output img`);
    findings.push(...(await axeFindings(page, "ui-sweep.R")));

    await page.goto(server.url);
    await page.waitForSelector(".ember-start-row");
    findings.push(...(await axeFindings(page, "start page")));

    assert.deepEqual(findings, []);
    assertNoProblems(page);
  });
}

// #294: a plot's text alternative is its cell's #| fig-alt, else its
// #| fig-cap, else "Plot".
test("plots: alt text from #| fig-alt or fig-cap, else \"Plot\" (#294)", async (t) => {
  const notebook = tempNotebook("ui-sweep.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "a11y-294.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const img = `${cellSelector("PLT")} pluto-output img`;
  const altBecomes = (alt) => page.waitForFunction(([sel, alt]) => document.querySelector(sel)?.getAttribute("alt") === alt,
    [img, alt]);

  await runCell(page, "PLT");
  await altBecomes("Plot");

  await setCellCode(page, "PLT", '#| fig-cap: Squares of x\nplot(x, x^2, type = "b")');
  await runCell(page, "PLT");
  await altBecomes("Squares of x");

  await setCellCode(page, "PLT", '#| fig-cap: Squares of x\n#| fig-alt: Line chart of x squared, rising\nplot(x, x^2, type = "b")');
  await runCell(page, "PLT");
  await altBecomes("Line chart of x squared, rising");
  assertNoProblems(page);
});

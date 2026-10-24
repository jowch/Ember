// #538, part B: the running cell is easy to find, and the light theme's
// states read as clearly as the dark theme's. On screen, the running code
// box has a blue outline, under reduced motion too. Off screen, the
// header's "Running i of n cells" shows ↑ or ↓ and a click goes to the
// cell. The light rails reach 3 : 1 on the page, and a stale output is
// greyed but readable.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { writeFileSync } from "node:fs";
import { startServer, tempDir, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector, waitIdle } from "../browser.mjs";
import { waitingFor } from "../waits.mjs";

/** A theme token as the computed colour a background set to it reads. */
const token = (page, name) =>
  page.evaluate((name) => {
    const probe = document.createElement("div");
    probe.style.background = `var(${name})`;
    document.body.appendChild(probe);
    const value = getComputedStyle(probe).backgroundColor;
    probe.remove();
    return value;
  }, name);

/** WCAG contrast of two computed rgb() colours. */
const contrast = (a, b) => {
  const lum = (c) => {
    const [r, g, bl] = c.match(/[\d.]+/g).slice(0, 3).map(Number).map((v) => v / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

/** A notebook whose last cell runs until stopped, below enough cells to be off screen. */
function longNotebook() {
  const notebook = path.join(tempDir("ember-e2e-running-"), "running.R");
  const fillers = Array.from({ length: 12 }, (_, i) => [`# %% id=F${i}`, `f${i} <- ${i}`, ""]).flat();
  writeFileSync(notebook, [
    "### An Ember notebook ###", "# /// environment", '# ember_version = "0.0.0.9000"', '# r_version = "4.6.1"', '# snapshot = "2026-01-01"', "# ///", "",
    ...fillers,
    "# %% id=LONG", "while (TRUE) Sys.sleep(0.1)", "",
  ].join("\n"), "utf8");
  return notebook;
}

test("running cell: a blue outline on screen, and the header points to it and goes there off screen (#538)", async (t) => {
  const notebook = longNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "running-cell.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 1440, height: 700 });
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "LONG");
  await page.waitForSelector(`${cellSelector("LONG")}[data-rail="run"]`);

  // On screen: the outline, though the rail can't pulse.
  const run = await token(page, "--ember-rail-run");
  const editor = page.locator(`${cellSelector("LONG")} .cm-editor:not(.cm-ssr-fake)`);
  assert.deepEqual(await editor.evaluate((el) => [getComputedStyle(el).outlineStyle, getComputedStyle(el).outlineColor]), ["solid", run]);
  assert.equal(await page.locator(`${cellSelector("LONG")} > pluto-trafficlight`).evaluate((el) => getComputedStyle(el).animationName), "none");
  const status = page.locator("#ember-r-status");
  assert.equal(await status.locator(".ember-r-status-where").count(), 0, "no arrow while the cell is in view");

  // Off screen above the fold: ↓, and the click goes there instead of opening Status.
  await page.evaluate(() => window.scrollTo(0, 0));
  const where = status.locator(".ember-r-status-where");
  await waitingFor("the header points down to the running cell", where.waitFor());
  assert.equal(await where.innerText(), "↓");
  assert.match(await status.getAttribute("aria-label"), /^Running \d+ of \d+ cells?\. Go to the running cell$/);
  await status.click();
  await waitingFor("the running cell scrolls into view", page.waitForFunction((sel) => {
    const r = document.querySelector(sel).getBoundingClientRect();
    return r.top >= 0 && r.bottom <= window.innerHeight;
  }, cellSelector("LONG")));
  await waitingFor("the arrow goes once the cell is in view", where.waitFor({ state: "detached" }));
  assert.equal(await page.locator("#ember-status-tab").count(), 0, "Status didn't open");

  // In view, the status opens Status as before.
  await status.click();
  await page.locator("#ember-status-tab").waitFor();

  await page.getByRole("button", { name: "Stop", exact: true }).click();
  await waitIdle(page);
  assertNoProblems(page);
});

test("state colours: light rails reach 3 : 1, and a stale output is greyed but readable (#538)", async (t) => {
  const notebook = tempNotebook("lazy.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "running-cell-stale.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ colorScheme: "light" });
  await openNotebook(page, server.origin, server.secret, notebook);
  const pageBg = await token(page, "--ember-page");
  for (const name of ["--ember-rail-run", "--ember-rail-due", "--ember-rail-err"]) {
    const c = contrast(await token(page, name), pageBg);
    assert.ok(c >= 3, `${name} on the page: ${c.toFixed(2)} : 1`);
  }

  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("2"), cellSelector("B") + " pluto-output");
  await waitIdle(page);
  await setCellCode(page, "A", "x <- 5");
  await runCell(page, "A");
  await page.waitForSelector(`${cellSelector("B")}.stale`);
  const output = page.locator(`${cellSelector("B")} > pluto-output`);
  for (const [scheme, want] of [["light", "0.65"], ["dark", "0.55"]]) {
    await page.emulateMedia({ colorScheme: scheme });
    await waitingFor(`stale output at ${want} in ${scheme}`,
      page.waitForFunction(([sel, want]) => getComputedStyle(document.querySelector(sel)).opacity === want, [`${cellSelector("B")} > pluto-output`, want]));
    assert.equal(await output.evaluate((el) => getComputedStyle(el).filter), "grayscale(1)");
  }
  assertNoProblems(page);
});

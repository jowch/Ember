// The side panel's state at load and the column's place beside it
// (docs/ui-3.md, Layout): open on Variables where it fits docked (from
// 1240 px), closed below that, and after that whatever this browser last
// chose. The column is centred and moves left only to clear the panel.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

const reload = async (page) => {
  await page.reload();
  await page.waitForSelector("pluto-cell", { timeout: 30000 });
  await page.waitForFunction(() => !document.querySelector("pluto-editor")?.classList.contains("loading"), null, { timeout: 30000 });
};

const selected_tab = (page) => page.locator('#helpbox-wrapper [role="tab"][aria-selected="true"]').innerText();

const setup = async (t, name) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), `panel-default-${name}.server.log`) });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });
  return { notebook, server, page: await newPage(browser) };
};

test("panel: open on Variables at 1440px with nothing stored, from the first paint, without taking focus", async (t) => {
  const { notebook, server, page } = await setup(t, "wide");
  // Records any moment the panel or the header's Variables icon showed as
  // closed, so a closed-then-open flash at load fails the test.
  await page.addInitScript(() => {
    window.__ember_closed_seen = [];
    new MutationObserver(() => {
      const panel = document.getElementById("helpbox-wrapper");
      if (panel != null && !panel.classList.contains("open")) window.__ember_closed_seen.push("panel");
      const icon = document.querySelector('header#pluto-nav button[aria-label="Variables"]');
      if (icon != null && icon.getAttribute("aria-pressed") !== "true") window.__ember_closed_seen.push("icon");
    }).observe(document, { subtree: true, childList: true, attributes: true });
  });
  await page.setViewportSize({ width: 1440, height: 900 });
  await openNotebook(page, server.origin, server.secret, notebook);

  assert.equal(await page.locator("#helpbox-wrapper.open").count(), 1, "the panel is open");
  assert.equal(await selected_tab(page), "Variables");
  assert.equal(await page.getByRole("button", { name: "Variables", exact: true }).getAttribute("aria-pressed"), "true");
  assert.deepEqual(await page.evaluate(() => [...new Set(window.__ember_closed_seen)]), [], "never shown closed during load");
  assert.equal(await page.evaluate(() => document.getElementById("helpbox-wrapper").contains(document.activeElement)), false, "focus stays out of the panel");

  // The safe-preview banner spans the window; its button stays clear of the panel.
  const run_button = page.getByRole("button", { name: "Run this notebook", exact: true });
  await run_button.waitFor({ state: "visible" });
  const button_on_top = await run_button.evaluate((el) => {
    const r = el.getBoundingClientRect();
    return el.contains(document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2));
  });
  assert.ok(button_on_top, "the panel does not cover the banner's Run button");

  assertNoProblems(page);
});

test("panel: closed at 1000px with nothing stored", async (t) => {
  const { notebook, server, page } = await setup(t, "narrow");
  await page.setViewportSize({ width: 1000, height: 800 });
  await openNotebook(page, server.origin, server.secret, notebook);

  assert.equal(await page.locator("#helpbox-wrapper.open").count(), 0, "the panel is closed");
  assert.equal(await page.getByRole("button", { name: "Variables", exact: true }).getAttribute("aria-pressed"), "false");

  assertNoProblems(page);
});

test("panel: closing it keeps it closed after a reload", async (t) => {
  const { notebook, server, page } = await setup(t, "close");
  await page.setViewportSize({ width: 1440, height: 900 });
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.getByRole("button", { name: "Variables", exact: true }).click();
  await page.waitForSelector("#helpbox-wrapper:not(.open)", { state: "attached" });
  await reload(page);

  assert.equal(await page.locator("#helpbox-wrapper.open").count(), 0, "still closed after the reload");
  assert.equal(await page.getByRole("button", { name: "Variables", exact: true }).getAttribute("aria-pressed"), "false");

  assertNoProblems(page);
});

test("panel: switching to Help reopens on Help after a reload", async (t) => {
  const { notebook, server, page } = await setup(t, "help");
  await page.setViewportSize({ width: 1440, height: 900 });
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.getByRole("tab", { name: "Help", exact: true }).click();
  assert.equal(await selected_tab(page), "Help");
  await reload(page);

  assert.equal(await page.locator("#helpbox-wrapper.open").count(), 1, "open after the reload");
  assert.equal(await selected_tab(page), "Help");
  assert.equal(await page.getByRole("button", { name: "Help", exact: true }).getAttribute("aria-pressed"), "true");

  assertNoProblems(page);
});

const geometry = (page) =>
  page.evaluate(() => {
    const main = document.querySelector("pluto-editor > main").getBoundingClientRect();
    const panel = document.getElementById("helpbox-wrapper").getBoundingClientRect();
    const run = document.querySelector("pluto-cell button.ember-run")?.getBoundingClientRect();
    const width = document.documentElement.clientWidth;
    return { main_left: main.left, main_right: main.right, main_width: main.width, panel_left: panel.left, run_left: run?.left ?? null, width };
  });

test("panel: the column clears the docked panel at 1440px and is centred at 2560px", async (t) => {
  const { notebook, server, page } = await setup(t, "geometry");
  await page.setViewportSize({ width: 1440, height: 900 });
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.waitForSelector("#helpbox-wrapper.open");

  const at_1440 = await geometry(page);
  assert.ok(Math.abs(at_1440.main_width - 751) <= 1, `the column keeps its width, got ${at_1440.main_width}`);
  assert.ok(at_1440.main_right <= at_1440.panel_left, `the column ends before the panel: ${JSON.stringify(at_1440)}`);
  assert.ok(at_1440.main_left > 0 && (at_1440.run_left == null || at_1440.run_left >= 0), `the run-button gutter is on screen: ${JSON.stringify(at_1440)}`);
  const left_1440 = at_1440.main_left, right_1440 = at_1440.width - at_1440.main_right;
  assert.ok(left_1440 < right_1440 - 10, `the column moved left of centre to clear the panel: ${JSON.stringify(at_1440)}`);

  await page.setViewportSize({ width: 2560, height: 1200 });
  await page.waitForTimeout(400);
  const at_2560 = await geometry(page);
  assert.ok(at_2560.main_right <= at_2560.panel_left, `the column ends before the panel: ${JSON.stringify(at_2560)}`);
  const left = at_2560.main_left, right = at_2560.width - at_2560.main_right;
  assert.ok(Math.abs(left - right) <= 3, `the column is centred at 2560px: left ${left}, right ${right}`);

  assertNoProblems(page);
});

// #538, part C: motion is short and says where a thing came from. Menus and
// dialogs fade in with a 4 px rise; the side panel slides in from its edge
// where it covers the notebook; the header no longer fades its colour; the
// progress bar is the running rail's blue, without the moving gradient.
// Reduced motion turns all of it off (a11y.test.mjs, 170).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector, hoverCell, waitIdle } from "../browser.mjs";

const animation = (page, sel) => page.locator(sel).evaluate((el) => [getComputedStyle(el).animationName, getComputedStyle(el).animationDuration]);

test("motion: menus and dialogs rise in, the panel slides over, the progress bar is plain blue (#538)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "motion.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await openNotebook(page, server.origin, server.secret, notebook);

  // The header keeps its hide-on-scroll slide but no 0.5 s colour fade.
  assert.equal(await page.locator("header#pluto-nav").evaluate((el) => getComputedStyle(el).transitionProperty), "transform");

  await page.getByRole("button", { name: "More", exact: true }).click();
  assert.deepEqual(await animation(page, "nav#at_the_top .ember-menu"), ["ember-pop", "0.13s"]);
  await page.getByRole("menuitem", { name: "Keyboard shortcuts", exact: true }).click();
  assert.deepEqual(await animation(page, "dialog.ember-shortcuts[open]"), ["ember-pop", "0.13s"]);
  assert.equal(await page.locator("dialog.ember-shortcuts[open]").evaluate((el) => getComputedStyle(el, "::backdrop").animationName), "ember-fade-in");
  await page.keyboard.press("Escape");
  await page.locator("dialog.ember-shortcuts").waitFor({ state: "detached" });

  await hoverCell(page, "A");
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  assert.deepEqual(await animation(page, 'div.input_context_menu[role="menu"]'), ["ember-pop", "0.13s"]);
  await page.keyboard.press("Escape");
  await page.locator('div.input_context_menu[role="menu"]').waitFor({ state: "detached" });

  // At 1200 px the panel covers the notebook, so it slides in from the right.
  await page.locator('header#pluto-nav button[aria-label="Variables"]').click();
  assert.deepEqual(await animation(page, "#helpbox-wrapper.open"), ["ember-slide-in", "0.18s"]);
  await page.locator('header#pluto-nav button[aria-label="Variables"]').click();
  await page.locator("#helpbox-wrapper.open").waitFor({ state: "detached" });

  // The progress bar while a run goes: one flat colour, the running rail's.
  await runCell(page, "LOOP");
  const bar = page.locator("loading-bar");
  await bar.waitFor();
  const [image, colour, name, rail] = await bar.evaluate((el) => {
    const probe = document.createElement("div");
    probe.style.background = "var(--ember-rail-run)";
    document.body.appendChild(probe);
    const rail = getComputedStyle(probe).backgroundColor;
    probe.remove();
    const s = getComputedStyle(el);
    return [s.backgroundImage, s.backgroundColor, s.animationName, rail];
  });
  assert.deepEqual([image, colour, name], ["none", rail, "none"]);
  await page.getByRole("button", { name: "Stop", exact: true }).click();
  await waitIdle(page);

  // On a phone the panel is a sheet, so it slides up from the bottom.
  await page.setViewportSize({ width: 600, height: 800 });
  await page.locator("#ember-r-status").click();
  assert.deepEqual(await animation(page, "#helpbox-wrapper.open"), ["ember-slide-up", "0.18s"]);
  assertNoProblems(page);
});

test("motion: a panel docked beside the notebook appears in place (#538)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "motion-docked.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 1440, height: 800 });
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#helpbox-wrapper.open").waitFor();
  assert.equal((await animation(page, "#helpbox-wrapper.open"))[0], "none");
  assertNoProblems(page);
});

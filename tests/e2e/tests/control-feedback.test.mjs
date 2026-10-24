// #538, part A: every control answers the pointer. The header's icon
// buttons and the R status fill on hover and darken while pressed; a menu
// lights one row, not the focused first item and the hovered one; an off
// switch can be seen; native radios take the accent; Copy output says it
// worked; and the start page's primary button is the notebook's filled one.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, tempDir, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector, hoverCell } from "../browser.mjs";
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

const background = (locator) => locator.evaluate((el) => getComputedStyle(el).backgroundColor);

/** Waits until `locator`'s background is `want`: the colours ease over 0.12 s. */
const backgroundBecomes = (page, locator, want, what) =>
  waitingFor(what, locator.evaluate((el, want) => new Promise((resolve) => {
    const check = () => (getComputedStyle(el).backgroundColor === want ? resolve() : requestAnimationFrame(check));
    check();
  }), want), () => background(locator));

/** WCAG contrast of two computed rgb() colours. */
const contrast = (a, b) => {
  const lum = (c) => {
    const [r, g, bl] = c.match(/[\d.]+/g).slice(0, 3).map(Number).map((v) => v / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

test("feedback: header buttons hover and press, one lit menu row, a visible off switch, accent radios, Copied (#538)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "control-feedback.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  if (process.env.EMBER_BROWSER !== "webkit") await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
  await openNotebook(page, server.origin, server.secret, notebook);
  const hover = await token(page, "--ember-hover");
  const active = await token(page, "--ember-active");

  for (const name of ["Variables", "Export"]) {
    const button = page.getByRole("button", { name, exact: true });
    const rest = await background(button);
    await button.hover();
    await backgroundBecomes(page, button, hover, `${name} filled on hover`);
    assert.notEqual(rest, hover, `${name} looks different under the pointer`);
    await page.mouse.down();
    await backgroundBecomes(page, button, active, `${name} darker while pressed`);
    await page.mouse.move(1, 1);
    await page.mouse.up();
    await page.keyboard.press("Escape");
  }
  const status = page.locator("#ember-r-status");
  await status.hover();
  await backgroundBecomes(page, status, hover, "the R status fills on hover");
  await page.mouse.move(1, 1);

  // A click opens the menu with focus on its first item, without lighting it.
  await page.getByRole("button", { name: "More", exact: true }).click();
  const items = page.locator(".ember-menu [role=menuitem]");
  await items.first().waitFor();
  const lit = () => items.evaluateAll((els, active) => els.map((el) => getComputedStyle(el).backgroundColor === active), active);
  await items.nth(1).hover();
  await backgroundBecomes(page, items.nth(1), active, "the hovered row");
  assert.deepEqual(await lit(), [false, true, false], "only the hovered row is lit");
  // Once the arrows move focus, the keyboard's row is the one lit.
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => document.activeElement?.matches(".ember-menu [role=menuitem]:focus-visible"));
  const focused = await items.evaluateAll((els) => els.indexOf(document.activeElement));
  await backgroundBecomes(page, items.nth(focused), active, "the keyboard's row");
  assert.equal((await lit()).filter(Boolean).length, 1, "one row lit with the pointer still on another");
  await page.keyboard.press("Escape");

  // The cell menu, likewise.
  await hoverCell(page, "B");
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  const cellItems = page.locator(`${cellSelector("B")} div.input_context_menu [role=menuitem]`);
  await cellItems.first().waitFor();
  await cellItems.nth(1).hover();
  await backgroundBecomes(page, cellItems.nth(1), active, "the hovered cell-menu row");
  const cellLit = await cellItems.evaluateAll((els, active) => els.map((el) => getComputedStyle(el).backgroundColor === active), active);
  assert.equal(cellLit.filter(Boolean).length, 1, `one cell-menu row lit: ${JSON.stringify(cellLit)}`);
  await page.keyboard.press("Escape");

  // Settings: an off switch is 3 : 1 against the dialog.
  await page.getByRole("button", { name: "More", exact: true }).click();
  await page.getByRole("menuitem", { name: "Settings", exact: true }).click();
  const dialog = page.locator("dialog.psettings[open]");
  await dialog.waitFor();
  const off = dialog.locator('.ember-switch[aria-checked="false"]').first();
  const [track, panel] = await off.evaluate((el) => [getComputedStyle(el).backgroundColor, getComputedStyle(el.closest("dialog")).backgroundColor]);
  assert.ok(contrast(track, panel) >= 3, `off switch ${track} on ${panel}: ${contrast(track, panel).toFixed(2)} : 1`);
  await dialog.getByRole("button", { name: "Done", exact: true }).click();

  // Native radios (Status, "When a cell changes") are the accent.
  await status.click();
  const radio = page.locator('#ember-status-tab input[type="radio"]').first();
  await radio.waitFor();
  assert.equal(await radio.evaluate((el) => getComputedStyle(el).accentColor), await token(page, "--ember-accent"));
  // Closed again: below 1240 px the panel covers the cells.
  await status.click();
  await page.waitForFunction(() => !document.querySelector("#helpbox-wrapper.open"));

  // Copy output: a note that it worked.
  if (process.env.EMBER_BROWSER !== "webkit") {
    await runCell(page, "B");
    await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("55"), cellSelector("B") + " pluto-output");
    await hoverCell(page, "B");
    await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
    await page.locator(`${cellSelector("B")} button.copy_output`).click();
    const note = page.locator("nav#ember-toast:not(.hidden)");
    await note.waitFor();
    assert.equal(await note.innerText(), "Output copied");
    assert.equal(await note.getAttribute("role"), "status", "read out by screen readers");
    assert.match(await page.evaluate(() => navigator.clipboard.readText()), /55/);
  }

  assertNoProblems(page);
});

test("feedback: the start page's primary button is the notebook's filled one, and answers the pointer (#538)", async (t) => {
  const dir = tempDir("ember-e2e-start-");
  const server = await startServer([], { cwd: dir, logFile: path.join(artifactsDir(), "control-feedback-start.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.goto(server.url);
  await page.locator(".ember-start-new-btn").click();
  await page.locator("#ember-start-new-name").fill("first");
  const create = page.getByRole("button", { name: "Create", exact: true });
  const accent = await token(page, "--ember-accent");
  assert.equal(await background(create), accent, "filled with the accent, as in the notebook");
  await create.hover();
  await waitingFor("Create darkens on hover", page.waitForFunction(([accent]) =>
    getComputedStyle([...document.querySelectorAll("button.ember-btn.primary")].find((b) => b.innerText === "Create")).backgroundColor !== accent, [accent]));
  assertNoProblems(page);
});

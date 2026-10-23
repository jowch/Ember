// #186: a cell that asks (readline(), menu()) waits for the answer under
// its console, as in an R console. The field takes focus when the cell was
// just run from its code, Enter sends the answer, and menu()'s choices are
// buttons too.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

const setup = async (t, name) => {
  const notebook = tempNotebook("prompts.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), `${name}.server.log`) });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });
  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  return page;
};

test("readline(): the answer typed under the cell goes to R, and the console shows it (#186)", async (t) => {
  const page = await setup(t, "prompts-readline");
  await runCell(page, "ASK");
  const input = page.locator(`${cellSelector("ASK")} ember-prompt input`);
  await input.waitFor({ timeout: 30000 });
  assert.equal(await page.locator(`${cellSelector("ASK")} ember-prompt .ember-prompt-text`).textContent(), "Name? ");
  // Run from its code, so the answer can be typed straight away.
  await page.waitForFunction((sel) => document.activeElement === document.querySelector(sel),
    `${cellSelector("ASK")} ember-prompt input`, { timeout: 10000 });
  await page.keyboard.type("Ada");
  await page.keyboard.press("Enter");
  await page.waitForSelector(`${cellSelector("ASK")}:not(.running)`, { timeout: 30000 });
  assert.equal(await page.locator(`${cellSelector("ASK")} ember-prompt`).count(), 0);
  const logs = await page.locator(`${cellSelector("ASK")} pluto-logs`).textContent();
  assert.match(logs, /Name\? Ada/);
  assert.match(logs, /Hello Ada/);
  await assertNoProblems(page);
});

test("menu(): a choice's button answers with its number (#186)", async (t) => {
  const page = await setup(t, "prompts-menu");
  await runCell(page, "MENU");
  const buttons = page.locator(`${cellSelector("MENU")} .ember-prompt-choices button`);
  await buttons.first().waitFor({ timeout: 30000 });
  assert.deepEqual(await buttons.allTextContents(), ["red", "blue"]);
  await buttons.nth(1).click();
  await page.waitForSelector(`${cellSelector("MENU")}:not(.running)`, { timeout: 30000 });
  assert.match(await page.locator(`${cellSelector("MENU")} pluto-output`).textContent(), /\[1\] 2/);
  await assertNoProblems(page);
});

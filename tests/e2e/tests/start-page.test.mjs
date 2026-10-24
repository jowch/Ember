// Tests 97 and 100 (docs/ui-3-tests.md, piece 4): the start page
// (GET /, StartPage.js) -- New notebook, the running row's round
// stop/close button, Forget, and "Open a file" with path completion. A
// new notebook opens ready to run; a file opened from disk opens in safe
// preview.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { startServer, artifactsDir, tempDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems } from "../browser.mjs";

test("start page: New notebook creates and opens it; the round button closes it to the recent rows; Forget removes it but keeps the file (97)", async (t) => {
  const dir = tempDir("ember-e2e-start-");
  const server = await startServer([], { cwd: dir, logFile: path.join(artifactsDir(), "start-page.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.goto(server.url);

  await page.locator(".ember-start-new-btn").click();
  const nameField = page.locator("#ember-start-new-name");
  await nameField.click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await page.keyboard.type("first");
  await page.getByRole("button", { name: "Create", exact: true }).click();

  await page.waitForURL(/edit\?id=/);
  // Made just now: it opens ready to run, with no safe-preview banner, as
  // a new notebook does in Pluto (design.md, safe preview). R starts at
  // once, so the status is never "waiting_for_permission".
  await page.waitForSelector("pluto-cell");
  assert.notEqual(await page.evaluate(() => window.editor_state.notebook.process_status), "waiting_for_permission");
  assert.equal(await page.getByRole("button", { name: "Run this notebook" }).count(), 0, "no safe-preview banner");
  const target = path.join(dir, "first.R");
  assert.ok(fs.existsSync(target), "the notebook file exists in the server's start folder");

  await page.goto(server.url);
  const openRow = page.locator(".ember-start-row", { has: page.locator(".ember-start-name", { hasText: "first.R" }) });
  await openRow.waitFor({ state: "visible" });

  // On a phone the folder gives way, not the name (#597).
  await page.setViewportSize({ width: 390, height: 844 });
  const [nameCut, folderCut] = await openRow.evaluate((row) =>
    [".ember-start-name", ".ember-start-folder"].map((sel) => { const el = row.querySelector(sel); return el.scrollWidth > el.clientWidth; }));
  assert.deepEqual([nameCut, folderCut], [false, true], "the folder truncates and the name shows whole");
  await page.setViewportSize({ width: 1200, height: 800 });

  await openRow.locator(".ember-start-stop").click();
  await page.waitForFunction(
    () => !document.querySelector(".ember-start-stop"));

  const recentRow = page.locator(".ember-start-row", { has: page.locator(".ember-start-name", { hasText: "first.R" }) });
  await recentRow.waitFor({ state: "visible" });
  await recentRow.locator(".ember-start-forget").click();

  await page.waitForFunction(
    () => !Array.from(document.querySelectorAll(".ember-start-name")).some((a) => a.textContent.includes("first.R")));
  assert.ok(fs.existsSync(target), "forgetting the notebook never deletes the file");

  assertNoProblems(page);
});

test("start page: Open a file completes a typed path and opens it in the editor (100)", async (t) => {
  const dir = tempDir("ember-e2e-start-open-");
  const nbPath = path.join(dir, "existing.R");
  fs.writeFileSync(nbPath, "### A Pluto.jl notebook ###\n");
  const server = await startServer([], { cwd: dir, logFile: path.join(artifactsDir(), "start-page-open.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.goto(server.url);

  // Typed the way a person types, with a pause before the last separator:
  // the list for the parent folder shows first, then the separator has to
  // ask for the folder's own entries. Before #124 the parent's list stayed
  // (it showed only this folder's own name), and in a temp folder with
  // over 200 entries this folder's name could be missing from it, so no
  // list showed at all (macOS, late in a CI run). No timeouts of our own:
  // each wait is for a list a completion request answered, and the test
  // runner's timeout bounds them.
  const openInput = page.locator(".ember-start-open-file .cm-content");
  await openInput.click();
  await page.keyboard.type(dir);
  const option = (name) => page.locator(".cm-tooltip-autocomplete li", { hasText: name });
  await option(path.basename(dir)).waitFor({ state: "visible" });
  await page.keyboard.type(path.sep);
  await option("existing.R").waitFor({ state: "visible" });
  await option("existing.R").click();

  await page.locator(".ember-start-open-file button").click();
  await page.waitForURL(/edit\?id=/);
  // A file from disk opens in safe preview, unlike a new notebook (97).
  await page.waitForSelector("pluto-cell");
  assert.equal(await page.evaluate(() => window.editor_state.notebook.process_status), "waiting_for_permission");
  await page.getByRole("button", { name: "Run this notebook" }).waitFor({ state: "visible" });

  assertNoProblems(page);
});

test("start page: Open a file finds a name past the first 200 entries of a big folder (#124)", async (t) => {
  // 250 folders that sort before the one we want: the server lists only
  // 200 entries, so the list for the bare folder can't include it, and
  // typing its name has to ask again rather than narrow that list.
  const dir = tempDir("ember-e2e-start-big-");
  for (let i = 0; i < 250; i++) fs.mkdirSync(path.join(dir, `a${String(i).padStart(3, "0")}`));
  fs.mkdirSync(path.join(dir, "zz-target"));
  const server = await startServer([], { cwd: dir, logFile: path.join(artifactsDir(), "start-page-big.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.goto(server.url);

  const option = (name) => page.locator(".cm-tooltip-autocomplete li", { hasText: name });
  await page.locator(".ember-start-open-file .cm-content").click();
  await page.keyboard.type(dir + path.sep);
  await option("a000/").waitFor({ state: "visible" });
  await page.keyboard.type("zz");
  await option("zz-target/").waitFor({ state: "visible" });

  assertNoProblems(page);
});

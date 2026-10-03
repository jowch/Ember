// Tests 97 and 100 (docs/ui-3-tests.md, piece 4): the start page
// (GET /, StartPage.js) -- New notebook, the running row's round
// stop/close button, Forget, and "Open a file" with path completion.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { startServer, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems } from "../browser.mjs";

test("start page: New notebook creates and opens it; the round button closes it to the recent rows; Forget removes it but keeps the file (97)", async (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), "ember-e2e-start-"));
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

  await page.waitForURL(/edit\?id=/, { timeout: 10000 });
  const target = path.join(dir, "first.R");
  assert.ok(fs.existsSync(target), "the notebook file exists in the server's start folder");

  await page.goto(server.url);
  const openRow = page.locator(".ember-start-row", { has: page.locator(".ember-start-name", { hasText: "first.R" }) });
  await openRow.waitFor({ state: "visible", timeout: 10000 });

  await openRow.locator(".ember-start-stop").click();
  await page.waitForFunction(
    () => !document.querySelector(".ember-start-stop"),
    null, { timeout: 10000 });

  const recentRow = page.locator(".ember-start-row", { has: page.locator(".ember-start-name", { hasText: "first.R" }) });
  await recentRow.waitFor({ state: "visible", timeout: 10000 });
  await recentRow.locator(".ember-start-forget").click();

  await page.waitForFunction(
    () => !Array.from(document.querySelectorAll(".ember-start-name")).some((a) => a.textContent.includes("first.R")),
    null, { timeout: 10000 });
  assert.ok(fs.existsSync(target), "forgetting the notebook never deletes the file");

  assertNoProblems(page);
});

test("start page: Open a file completes a typed path and opens it in the editor (100)", async (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), "ember-e2e-start-open-"));
  const nbPath = path.join(dir, "existing.R");
  fs.writeFileSync(nbPath, "### A Pluto.jl notebook ###\n");
  const server = await startServer([], { cwd: dir, logFile: path.join(artifactsDir(), "start-page-open.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.goto(server.url);

  const openInput = page.locator(".ember-start-open-file .cm-content");
  await openInput.click();
  await page.keyboard.type(dir + path.sep);
  await page.waitForSelector(".cm-tooltip-autocomplete li", { timeout: 5000 });
  await page.getByText("existing.R", { exact: false }).first().click();

  await page.locator(".ember-start-open-file button").click();
  await page.waitForURL(/edit\?id=/, { timeout: 10000 });

  assertNoProblems(page);
});

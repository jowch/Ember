// Markdown cells are editable (docs/ui.md, "Decisions"): editing and
// running one re-renders with the new content.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, runCell, cellSelector } from "../browser.mjs";

test("markdown: editing and running a markdown cell renders the new text", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "markdown.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await setCellCode(page, "MD", "# Changed\n\nNew text.");
  await runCell(page, "MD");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Changed"),
    cellSelector("MD") + " pluto-output", { timeout: 15000 });

  assertNoProblems(page);
});

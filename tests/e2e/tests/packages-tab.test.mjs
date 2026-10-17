// The Packages tab mid-install (board Panel3): the installing row stays one
// table row, and Update is Panel3's 30 px button on the title's line.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SLOW_INSTALLER = path.join(HERE, "..", "..", "testthat", "fixtures", "slow-installer.R");

test("packages tab: an installing row keeps its cells side by side; Update is a 30 px button", async (t) => {
  const notebook = tempNotebook("failing.R");
  const server = await startServer([notebook], {
    installerScript: SLOW_INSTALLER,
    logFile: path.join(artifactsDir(), "packages-tab.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "S");
  await page.getByRole("button", { name: "Packages", exact: true }).click();
  const row = page.locator("tr.ember-package-row.ember-package-installing");
  await row.waitFor({ timeout: 30000 });

  assert.equal(await row.evaluate((el) => getComputedStyle(el).display), "table-row");
  const cells = await row.locator("td").evaluateAll((tds) => tds.map((td) => td.getBoundingClientRect()).map((r) => ({ top: r.top, left: r.left })));
  assert.equal(cells.length, 3);
  assert.ok(cells.every((c) => c.top === cells[0].top), `name, version and status share a line: ${JSON.stringify(cells)}`);
  assert.ok(cells[0].left < cells[1].left && cells[1].left < cells[2].left, "name, then version, then status");
  assert.equal(await row.locator("td").first().innerText(), "brokenpkg");

  // Panel3's table: a quiet 11.5 px header on the panel's line colour,
  // 12.5 px rows, and fixed columns of 32 % and 24 % with the rest for Status.
  const table = await page.locator(".ember-packages-table").evaluate((el) => {
    const th = getComputedStyle(el.querySelector("th"));
    const td = getComputedStyle(el.querySelector("tbody td"));
    const widths = [...el.querySelectorAll("th")].map((h) => h.getBoundingClientRect().width / el.getBoundingClientRect().width);
    const probe = document.createElement("span");
    probe.style.color = "var(--ember-faint)";
    el.appendChild(probe);
    const faint = getComputedStyle(probe).color;
    probe.remove();
    return { size: th.fontSize, weight: th.fontWeight, colorIsFaint: th.color === faint, bodySize: td.fontSize, layout: getComputedStyle(el).tableLayout, widths };
  });
  assert.deepEqual({ ...table, widths: undefined }, { size: "11.5px", weight: "500", colorIsFaint: true, bodySize: "12.5px", layout: "fixed", widths: undefined });
  assert.ok(Math.abs(table.widths[0] - 0.32) < 0.01 && Math.abs(table.widths[1] - 0.24) < 0.01, `columns 32 % and 24 %: ${JSON.stringify(table.widths)}`);

  // A name longer than its column wraps inside it: the column stays 32 %
  // and nothing of the name is hidden.
  const long = await row.locator("td").first().evaluate((td) => {
    td.textContent = "TxDb.Hsapiens.UCSC.hg38.knownGene";
    const table = td.closest("table");
    return {
      fits: td.scrollWidth <= td.clientWidth,
      width: table.querySelector("th").getBoundingClientRect().width / table.getBoundingClientRect().width,
    };
  });
  assert.ok(long.fits, `the long name fits its cell: ${JSON.stringify(long)}`);
  assert.ok(Math.abs(long.width - 0.32) < 0.01, `the name column stays 32 %: ${JSON.stringify(long)}`);

  const update = page.locator(".ember-packages-update button");
  const style = await update.evaluate((el) => {
    const cs = getComputedStyle(el);
    return { height: cs.height, radius: cs.borderTopLeftRadius, border: cs.borderTopWidth, size: cs.fontSize, weight: cs.fontWeight, family: cs.fontFamily.split(",")[0] };
  });
  assert.deepEqual(style, { height: "30px", radius: "7px", border: "1px", size: "12.5px", weight: "500", family: "Figtree" });
  const title = await page.locator(".ember-packages-title").boundingBox();
  const button = await update.boundingBox();
  assert.ok(Math.abs(title.y + title.height / 2 - (button.y + button.height / 2)) <= 1, "Update is centred on the title's line");

  assertNoProblems(page);
});

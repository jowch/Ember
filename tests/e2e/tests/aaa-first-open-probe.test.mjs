// Temporary measurement for #417 and #529, not to merge: where a first
// open spends its time on a CI runner. Named to run first, beside the
// suite's other first files, as the slow opens did. Each open is a fresh
// server, browser and page, three at once, ten rounds. Times are from the
// open's start; any open over 5 s also lists every request that took over
// 1 s, failed, or never finished. Prints only; asserts nothing.

import { test } from "node:test";
import { startServer, tempNotebook } from "../server.mjs";
import { launchBrowser, newPage } from "../browser.mjs";

async function probe(label) {
  const notebook = tempNotebook();
  const t0 = Date.now();
  const at = () => ((Date.now() - t0) / 1000).toFixed(2);
  const marks = [];
  const mark = (name) => marks.push(`${name} ${at()}`);
  let server, browser;
  const requests = new Map();
  try {
    server = await startServer([notebook], { timeoutMs: 0 });
    mark("server");
    browser = await launchBrowser();
    mark("browser");
    const page = await newPage(browser);
    page.on("request", (r) => requests.set(r, { url: r.url().split("?")[0].replace(server.origin, "/"), start: Date.now() }));
    page.on("requestfinished", (r) => { const q = requests.get(r); if (q) q.end = Date.now(); });
    page.on("requestfailed", (r) => { const q = requests.get(r); if (q) { q.end = Date.now(); q.failed = r.failure()?.errorText; } });
    page.once("domcontentloaded", () => mark("dom"));
    page.once("load", () => mark("load"));
    page.on("websocket", (ws) => {
      mark("ws open");
      ws.once("framereceived", () => mark("first frame"));
    });
    const url = `${server.origin}open?path=${encodeURIComponent(notebook)}&secret=${server.secret}`;
    await page.goto(url);
    mark("goto");
    await page.waitForSelector("pluto-cell");
    mark("pluto-cell");
    await page.waitForFunction(() => !document.querySelector("pluto-editor")?.classList.contains("loading"));
    mark("loaded");
    await page.waitForFunction(() => {
      const order = window.editor_state?.notebook?.cell_order;
      return Array.isArray(order) && order.every((id) => document.querySelector(`pluto-cell[id="${id}"]`));
    });
    mark("all cells");
  } finally {
    await browser?.close();
    await server?.stop();
  }
  const total = (Date.now() - t0) / 1000;
  let line = `${label}: ${marks.join(", ")}`;
  if (total > 5) {
    const slow = [...requests.values()].filter((q) => q.end === undefined || q.failed || q.end - q.start > 1000)
      .map((q) => `${q.url} ${q.end === undefined ? "never finished" : ((q.end - q.start) / 1000).toFixed(2) + " s"}${q.failed ? " failed " + q.failed : ""}`);
    line += `\n  slow requests: ${slow.length ? slow.join("; ") : "none"}`;
  }
  return { total, line };
}

test("measure: where a first open spends its time (#417, #529)", async () => {
  const results = [];
  for (let round = 1; round <= 10; round++) {
    results.push(...await Promise.all([1, 2, 3].map((k) => probe(`round ${round} open ${k}`))));
  }
  for (const r of results) console.log(r.line);
  const totals = results.map((r) => r.total).sort((a, b) => a - b);
  const q = (p) => totals[Math.min(totals.length - 1, Math.floor(p * totals.length))].toFixed(2);
  const summary = `first opens on ${process.platform}: ${totals.length} opens, median ${q(0.5)} s, p90 ${q(0.9)} s, max ${totals.at(-1).toFixed(2)} s`;
  console.log(process.env.GITHUB_ACTIONS ? `::notice title=first-open probe::${summary}` : summary);
});

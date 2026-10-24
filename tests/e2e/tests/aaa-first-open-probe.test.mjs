// Temporary measurement for #417 and #529, not to merge: what happens
// between a first open's first socket frame and its first pluto-cell, the
// wait that was 3 to 4 s for round 1 on windows-latest (#417). Each open
// is a fresh server, browser and page, three at once, ten rounds, as on
// #533. For round 1, and for any open whose wait is over 1.5 s, it prints
// every socket frame but the clock's (direction, message type, bytes) and every ember
// function in the server that took 50 ms or more, both timed from the
// open's start. The server's functions are traced with trace(), which
// slows every call a little, on every round alike. Prints only; asserts
// nothing.

import { test } from "node:test";
import { startServer, tempNotebook } from "../server.mjs";
import { launchBrowser, newPage } from "../browser.mjs";

// Every function in ember's namespace gets an entry time and, on exit, a
// "PROBE <epoch s> <name> <elapsed s>" line on stderr if it took 50 ms or
// more. A function whose body replaces on.exit() loses its line.
const TRACE = `local({
  ns <- asNamespace("ember")
  for (n in ls(ns, all.names = TRUE)) {
    f <- get0(n, envir = ns, inherits = FALSE)
    if (!is.function(f) || is.primitive(f) || startsWith(n, ".__")) next
    exit <- bquote(if (exists(".probe_t0", inherits = FALSE) && proc.time()[[3]] - .probe_t0 >= 0.05)
      cat(sprintf("PROBE %.3f %s %.3f\\n", as.numeric(Sys.time()), .(n), proc.time()[[3]] - .probe_t0), file = stderr()))
    try(suppressMessages(trace(n, tracer = quote(.probe_t0 <- proc.time()[[3]]), exit = exit, where = ns, print = FALSE)), silent = TRUE)
  }
}); `;

// Records every frame of every socket the page opens, with Date.now(), so
// the times line up with the probe's own and the server's.
const RECORD_FRAMES = () => {
  window.__probe_frames = [];
  const Base = window.WebSocket;
  window.WebSocket = class extends Base {
    constructor(...args) {
      super(...args);
      this.addEventListener("message", (e) => window.__probe_frames.push({ dir: "in", t: Date.now(), data: e.data }));
    }
    send(data) {
      window.__probe_frames.push({ dir: "out", t: Date.now(), data });
      super.send(data);
    }
  };
};

async function frames(page) {
  return page.evaluate(async () => {
    const { unpack } = await import("/common/MsgPack.js");
    const out = [];
    for (const f of window.__probe_frames) {
      const buf = f.data instanceof Blob ? await f.data.arrayBuffer() : f.data;
      let type = "?";
      try { type = unpack(new Uint8Array(buf)).type ?? "?"; } catch { /* left as ? */ }
      out.push({ dir: f.dir, t: f.t, type, bytes: buf.byteLength ?? String(buf).length });
    }
    return out;
  });
}

async function probe(label, round) {
  const notebook = tempNotebook();
  const t0 = Date.now();
  const at = () => ((Date.now() - t0) / 1000).toFixed(2);
  const rel = (ms) => ((ms - t0) / 1000).toFixed(2);
  const times = {};
  const marks = [];
  const mark = (name) => { times[name] = Date.now(); marks.push(`${name} ${at()}`); };
  let server, browser, recorded = [], log = "";
  try {
    server = await startServer([notebook], { timeoutMs: 0, probePrelude: TRACE });
    mark("server");
    browser = await launchBrowser();
    mark("browser");
    const page = await newPage(browser);
    await page.addInitScript(RECORD_FRAMES);
    page.on("websocket", (ws) => {
      mark("ws open");
      ws.once("framereceived", () => mark("first frame"));
    });
    const url = `${server.origin}open?path=${encodeURIComponent(notebook)}&secret=${server.secret}`;
    await page.goto(url);
    mark("goto");
    await page.waitForSelector("pluto-cell");
    mark("pluto-cell");
    await page.waitForFunction(() => {
      const order = window.editor_state?.notebook?.cell_order;
      return Array.isArray(order) && order.every((id) => document.querySelector(`pluto-cell[id="${id}"]`));
    });
    mark("all cells");
    recorded = await frames(page);
    log = server.log();
  } finally {
    await browser?.close();
    await server?.stop();
  }
  const wait = (times["pluto-cell"] - times["first frame"]) / 1000;
  let line = `${label}: ${marks.join(", ")}; first frame to pluto-cell ${wait.toFixed(2)} s`;
  if (round === 1 || wait > 1.5) {
    const from = times["ws open"] - 500, to = times["pluto-cell"];
    const shown = recorded.filter((f) => f.t <= to);
    const clock = shown.filter((f) => f.type === "current_time").length;
    line += "\n  frames: " + shown.filter((f) => f.type !== "current_time").map((f) => `${rel(f.t)} ${f.dir} ${f.type} ${f.bytes}B`).join("; ") +
      ` (and ${clock} current_time frames)`;
    const calls = [...log.matchAll(/^PROBE (\S+) (\S+) (\S+)$/gm)]
      .map((m) => ({ end: Number(m[1]) * 1000, name: m[2], took: Number(m[3]) }))
      .filter((c) => c.end >= from && c.end - c.took * 1000 <= to);
    line += "\n  server calls of 50 ms or more, ending in [ws open - 0.5 s, pluto-cell]: " +
      (calls.length ? calls.map((c) => `${c.name} ${rel(c.end - c.took * 1000)}-${rel(c.end)}`).join("; ") : "none");
    const other = log.split("\n").filter((l) => l.trim() && !l.startsWith("PROBE ") && !/Tracing|Untracing/.test(l));
    line += "\n  rest of the server log: " + (other.length ? other.slice(-12).join(" | ") : "empty");
  }
  return { wait, line };
}

test("measure: what a first open waits on before its first cell (#417, #529)", async () => {
  const results = [];
  for (let round = 1; round <= 10; round++) {
    results.push(...await Promise.all([1, 2, 3].map((k) => probe(`round ${round} open ${k}`, round))));
  }
  for (const r of results) console.log(r.line);
  const waits = results.map((r) => r.wait).sort((a, b) => a - b);
  const summary = `first frame to pluto-cell on ${process.platform}: ${waits.length} opens, median ${waits[15].toFixed(2)} s, max ${waits.at(-1).toFixed(2)} s; ` +
    `round 1: ${results.slice(0, 3).map((r) => r.wait.toFixed(2)).join(", ")} s`;
  console.log(process.env.GITHUB_ACTIONS ? `::notice title=first-open probe::${summary}` : summary);
});

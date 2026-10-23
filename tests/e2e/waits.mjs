// What each test is waiting for, so a test that never gets what it waits
// for still says what that was.
//
// No wait in this suite has a time limit of its own (docs/ui-tests.md,
// section 3): a wait ends when what it waits for happens. This module
// keeps a list of every Playwright call still pending, and every wait
// labelled with waitingFor(), with where the test started it. A wait that
// never ends shows up in one of two ways:
//
// - The test waits until run.mjs's --test-timeout stops the file. Under
//   Node 22 that bound is per file: the runner ends the file's process
//   and drops whatever it prints after that. So the list is kept in
//   test-results/waiting-<file>.txt, rewritten at most once a second while
//   a wait is pending, and run.mjs prints any list a file leaves behind.
//   Where the process gets a signal first (not on Windows, where the
//   runner's stop is abrupt), server.mjs calls stateOnStop(), which adds
//   what each page shows.
// - The test ends some other way (it failed) while a wait it started is
//   still pending. The afterEach hook below prints the list, with what
//   each page shows.
//
// A pending wait also keeps node running. Playwright's connection to the
// browser and server.mjs's children don't, and without a time limit
// nothing else would: node:test would cancel the test as soon as nothing
// else was left to do ("Promise resolution is still pending but the event
// loop has already resolved"), though the browser was about to answer.
//
// What a page shows: its URL, its connection, the notebook's running,
// queued and errored cells, where the focus is, and the state any labelled
// wait asked for.

import { appendFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { afterEach, beforeEach } from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FILE = path.join(HERE, "test-results", `waiting-${path.basename(process.argv[1] ?? "node")}.txt`);

/** Every wait still pending: what it waits on, where, since when. */
const pending = new Map();
let nextId = 0;
/** Pages seen, each with its last console lines. */
const pages = new Set();
/** More of the report, from server.mjs: its servers' logs. */
const sections = [];
let written = false;
let stopping = false;
let timer = null;
let keepAlive = null;
let testName = null;

/** Adds `fn()`'s text to every report. */
export function addSection(fn) { sections.push(fn); }


// Where the test called the wait: the first frames in this folder's own
// files, outside this one.
function callSite() {
  const frames = [];
  for (const line of new Error().stack.split("\n").slice(1)) {
    const m = line.match(/\(?((?:file:\/\/\/?)?[^()\s]+?):(\d+):\d+\)?$/);
    if (!m) continue;
    let file = m[1];
    try { if (file.startsWith("file:")) file = fileURLToPath(file); } catch { continue; }
    if (!path.isAbsolute(file)) continue;
    const rel = path.relative(HERE, file);
    if (rel.startsWith("..") || path.isAbsolute(rel) || rel.includes("node_modules") || rel === "waits.mjs") continue;
    frames.push(`${rel.replaceAll("\\", "/")}:${m[2]}`);
    if (frames.length === 3) break;
  }
  return frames.join(" < ");
}

function compact(value) {
  let text;
  if (typeof value === "function") text = value.toString();
  else if (typeof value === "string") text = JSON.stringify(value);
  else { try { text = JSON.stringify(value); } catch { text = String(value); } }
  text = (text ?? String(value)).replace(/\s+/g, " ");
  return text.length > 240 ? text.slice(0, 237) + "..." : text;
}

function schedule() {
  // Coalesced, at most once a second; unref'd, so it never keeps the
  // process alive.
  if (timer) return;
  timer = setTimeout(() => { timer = null; if (!stopping) write(); }, 1000);
  timer.unref();
}

function report(when) {
  const now = Date.now();
  const lines = [`${path.basename(FILE)}: ${when}, ${new Date(now).toISOString()}`];
  if (testName) lines.push(`test: ${testName}`);
  lines.push("waiting for:");
  for (const w of pending.values()) {
    lines.push(`  - ${w.label}`, `      at ${w.site || "?"}, for ${((now - w.since) / 1000).toFixed(1)} s`);
  }
  for (const page of pages) {
    let url = "?";
    try { url = page.url().replace(/secret=[^&]+/, "secret=..."); } catch { /* closed */ }
    lines.push(`page ${url}`);
    for (const c of page.recentConsole ?? []) lines.push(`  console: ${c}`);
  }
  for (const fn of sections) {
    try { const text = fn(); if (text) lines.push(text); } catch (e) { lines.push(`(a section failed: ${e.message})`); }
  }
  return lines.join("\n") + "\n";
}

function write() {
  try {
    if (pending.size === 0) {
      if (written) rmSync(FILE, { force: true });
      written = false;
      return;
    }
    mkdirSync(path.dirname(FILE), { recursive: true });
    writeFileSync(FILE, report("still pending"));
    written = true;
  } catch { /* best effort */ }
}

function track(promise, entry) {
  const id = nextId++;
  pending.set(id, { ...entry, since: Date.now() });
  keepAlive ??= setInterval(() => {}, 60000);
  schedule();
  const done = () => {
    pending.delete(id);
    if (pending.size === 0) { clearInterval(keepAlive); keepAlive = null; }
    schedule();
  };
  promise.then(done, done);
  return promise;
}

/** `promise`, listed in the report as `label`; `state()`, if given, is
 * what the report adds about it when the process is stopped (an async
 * function of the page, say). For a wait whose own description wouldn't
 * say what it is for. */
export function waitingFor(label, promise, state) {
  return track(promise, { label: JSON.stringify(label), site: callSite(), state });
}

// Calls that return at once, or only build a locator, aren't tracked.
const UNTRACKED = new Set(["constructor", "context", "opener", "mainFrame", "frame", "frames", "setDefaultNavigationTimeout",
  "setDefaultTimeout", "video", "url", "viewportSize", "isClosed", "locator", "frameLocator", "requests", "workers", "page",
  "filter", "visible", "describe", "description", "first", "last", "nth", "and", "or", "toString", "contentFrame",
  "consoleMessages", "pageErrors", "clearConsoleMessages", "clearPageErrors"]);

let rawEvaluate = null;

function wrap(proto, describe) {
  for (const name of Object.getOwnPropertyNames(proto)) {
    if (name.startsWith("_") || name.startsWith("getBy") || UNTRACKED.has(name)) continue;
    const desc = Object.getOwnPropertyDescriptor(proto, name);
    if (typeof desc.value !== "function") continue;
    const original = desc.value;
    proto[name] = function (...args) {
      const result = original.apply(this, args);
      if (!result || typeof result.then !== "function") return result;
      const page = describe.page(this);
      if (page) watchPage(page);
      return track(result, { label: `${describe.name(this)}.${name}(${args.map(compact).join(", ")})`, site: callSite(), page });
    };
  }
}

function install(page) {
  if (rawEvaluate) return;
  const pageProto = Object.getPrototypeOf(page);
  rawEvaluate = pageProto.evaluate;
  wrap(pageProto, { name: () => "page", page: (p) => p });
  wrap(Object.getPrototypeOf(page.locator("html")), { name: (l) => String(l), page: (l) => l.page() });
}

/** Keeps `page`'s last console lines for the report. */
export function watchPage(page) {
  if (pages.has(page)) return;
  pages.add(page);
  page.recentConsole = [];
  page.on("console", (m) => {
    page.recentConsole.push(`${m.type()}: ${m.text()}`.slice(0, 300));
    if (page.recentConsole.length > 10) page.recentConsole.shift();
  });
  page.once("close", () => pages.delete(page));
}

/** `browser`, with no default time limit on any Playwright call in a
 * context it makes (Playwright's own default is 30 s), and every page in
 * those contexts tracked. */
export function untimed(browser) {
  const newContext = browser.newContext.bind(browser);
  browser.newContext = async (...args) => {
    const context = await newContext(...args);
    context.setDefaultTimeout(0);
    context.on("page", (page) => { install(page); watchPage(page); });
    return context;
  };
  return browser;
}

// What a page shows, asked without tracking the question.
async function pageState(page) {
  const state = await rawEvaluate.call(page, () => {
    const nb = window.editor_state?.notebook;
    const c = window.ember_connection;
    const cells = nb ? Object.entries(nb.cell_results ?? {}).filter(([, r]) => r.running || r.queued || r.errored)
      .map(([id, r]) => `${id} ${r.running ? "running" : r.queued ? "queued" : "errored"}`) : null;
    return {
      connection: c ? `${c.state}, key checks out ${c.key_checks_out}` : null,
      process_status: nb?.process_status ?? null,
      cells,
      focus: document.activeElement?.closest?.("pluto-cell")?.id ?? document.activeElement?.tagName ?? null,
    };
  });
  return JSON.stringify(state);
}

// Each page's state and each labelled wait's, asked for at most 5 s, so a
// page that doesn't answer still lets the report end.
async function states() {
  const asks = [];
  for (const page of pages) {
    asks.push(pageState(page).then((s) => `page ${page.url().replace(/secret=[^&]+/, "secret=...")}: ${s}`,
      (e) => `page: no state (${e.message.split("\n")[0]})`));
  }
  for (const w of pending.values()) {
    if (w.state) asks.push(Promise.resolve().then(w.state).then((s) => `${w.label}: ${compact(s)}`, (e) => `${w.label}: no state (${e.message.split("\n")[0]})`));
  }
  const lines = [];
  const cap = new Promise((resolve) => setTimeout(resolve, 5000).unref());
  await Promise.race([Promise.all(asks.map((a) => a.then((text) => lines.push(`  ${text}`)))), cap]);
  return lines;
}

/** Called on a signal, before the process exits: writes the report, then
 * adds each page's state and each labelled wait's. */
export async function stateOnStop() {
  if (pending.size === 0) return;
  stopping = true;
  try {
    mkdirSync(path.dirname(FILE), { recursive: true });
    writeFileSync(FILE, report("stopped"));
    written = true;
    appendFileSync(FILE, ["state when stopped:", ...(await states())].join("\n") + "\n");
  } catch { /* best effort */ }
}

if (process.env.NODE_TEST_CONTEXT) {
  beforeEach((t) => { testName = t.name; });
  // Before the test's own after hooks, which close its browser.
  afterEach(async () => {
    if (pending.size === 0) return;
    console.log(report("still pending when the test ended") + ["state:", ...(await states())].join("\n"));
    // Reported, so let them go: a wait no browser close will settle (a
    // file poll, sentMessages().reach) would otherwise keep node running,
    // and the rest of the file would wait for the runner's stop.
    pending.clear();
    clearInterval(keepAlive);
    keepAlive = null;
  });
}

process.on("exit", () => {
  if (stopping) return;
  if (pending.size > 0) {
    try { mkdirSync(path.dirname(FILE), { recursive: true }); writeFileSync(FILE, report("pending when the process ended")); } catch { /* best effort */ }
  } else if (written) {
    try { rmSync(FILE, { force: true }); } catch { /* best effort */ }
  }
});

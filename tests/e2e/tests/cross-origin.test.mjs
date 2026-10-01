// review4 item 1 (CRITICAL): the websocket used to accept the ember_secret
// cookie and never checked Origin, so a page served by *any* other local
// server on 127.0.0.1 could open a websocket to the Ember server and run
// code, because the browser attaches a host's cookies (even HttpOnly ones)
// to every request to that host regardless of which port's page sent it,
// and cookies ignore port entirely (RFC 6265). The fix: the websocket
// requires `?secret=` in its own URL and never accepts the cookie, and
// both the websocket and every HTTP route reaching R check Origin/Host
// against the server's own 127.0.0.1:<port>.
//
// This reproduces the reviewer's attacker.html/xorigin.mjs finding: a
// victim tab opens the real notebook (so the browser now holds the
// server's secret cookie); a second tab, pointed at a *different* local
// server's page, tries to piggyback on that cookie to connect and run a
// cell that writes a file -- proving it over the side effect (the file
// must never be created), not just a status code.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import http from "node:http";
import { mkdtempSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, openNotebook } from "../browser.mjs";

/** A minimal local HTTP server standing in for "some other program on this
 * machine": it answers every request with an HTML page that opens a raw
 * websocket to the Ember server at `victimPort` and tries to run arbitrary
 * code. Not an Ember server itself -- a different origin (different port,
 * no knowledge of Ember's secret), which is exactly the threat model
 * design.md's Processes section names. */
function attackerHtml(victimPort, pwnedPath) {
  return `<!doctype html><html><body><script>
function enc(v){const out=[];const te=new TextEncoder();
 function w(x){
  if(typeof x==="string"){const b=te.encode(x);if(b.length<32)out.push(0xa0|b.length);else{out.push(0xd9,b.length)}out.push(...b)}
  else if(x===null)out.push(0xc0);
  else if(typeof x==="boolean")out.push(x?0xc3:0xc2);
  else if(Array.isArray(x)){out.push(0x90|x.length);x.forEach(w)}
  else{const k=Object.keys(x);out.push(0x80|k.length);k.forEach(kk=>{w(kk);w(x[kk])})}}
 w(v);return new Uint8Array(out)}
window.result = { events: [] };
const ws = new WebSocket("ws://127.0.0.1:${victimPort}/");
ws.binaryType = "arraybuffer";
ws.onopen = () => { window.result.events.push("open");
  ws.send(enc({type:"get_all_notebooks", client_id:"evil", request_id:"r1", notebook_id:null, body:{}})); };
let step = 0;
const NEW = "11111111-2222-3333-4444-555555555555";
ws.onmessage = (m) => { const txt = new TextDecoder().decode(new Uint8Array(m.data));
  window.result.events.push("message:" + txt.slice(0,200).replace(/[^\\x20-\\x7e]/g,"."));
  if (step === 0) { step = 1;
    const mm = txt.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/);
    const nb = mm ? mm[0] : "00000000-0000-4000-8000-000000000000";
    ws.send(enc({type:"connect", client_id:"evil", request_id:"r2", notebook_id:nb, body:{}}));
    ws.send(enc({type:"update_notebook", client_id:"evil", request_id:"r3", notebook_id:nb, body:{updates:[]}}));
    setTimeout(() => {
      ws.send(enc({type:"update_notebook", client_id:"evil", request_id:"r4", notebook_id:nb, body:{updates:[
        {op:"add", path:["cell_inputs", NEW], value:{cell_id:NEW, code:"writeLines('pwned', '${pwnedPath.replace(/\\/g, "\\\\")}')", code_folded:false}}]}}));
      ws.send(enc({type:"run_multiple_cells", client_id:"evil", request_id:"r5", notebook_id:nb, body:{cells:[NEW]}}));
    }, 300);
  }
};
ws.onclose = (e) => window.result.events.push("close:" + e.code);
</script></body></html>`;
}

function startAttackerServer(html) {
  return new Promise((resolve) => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(html);
    });
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

test("cross-origin: a page on another local server can't connect or run code via the secret cookie", async (t) => {
  const notebook = tempNotebook();
  const dir = mkdtempSync(path.join(tmpdir(), "ember-e2e-xorigin-"));
  const pwned = path.join(dir, "pwned.txt");

  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cross-origin.server.log") });
  const victimPort = Number(new URL(server.url).port);
  const attackerHttp = await startAttackerServer(attackerHtml(victimPort, pwned));
  const attackerOrigin = `http://127.0.0.1:${attackerHttp.address().port}/`;

  const browser = await launchBrowser();
  t.after(async () => {
    await browser.close();
    server.stop();
    await new Promise((r) => attackerHttp.close(r));
  });

  const ctx = await browser.newContext();
  const victimPage = await ctx.newPage();
  await openNotebook(victimPage, server.origin, server.secret, notebook); // sets the ember_secret_<port> cookie
  const cookies = await ctx.cookies();
  assert.ok(cookies.some((c) => c.name.startsWith("ember_secret")), "the victim tab holds the secret cookie");

  // Same browser context (same cookie jar), different origin: the cookie
  // *is* sent automatically to the victim's port (cookies ignore port), but
  // the fix must refuse the connection anyway.
  const attackerPage = await ctx.newPage();
  await attackerPage.goto(attackerOrigin);
  await attackerPage.waitForTimeout(3000);
  const result = await attackerPage.evaluate(() => window.result);

  assert.ok(result.events.includes("open"), "the TCP/websocket handshake itself still completes (it's refused at the app layer)");
  assert.ok(!result.events.some((e) => e.startsWith("message:")),
    "no reply (notebook list, connect ack, or anything else) ever reaches the other origin: " + JSON.stringify(result.events));
  assert.ok(result.events.some((e) => e.startsWith("close:")), "the server closes the socket");
  assert.ok(!existsSync(pwned), "the attacker's cell never ran: the target file must not exist");

  // Control: a context with no cookie at all behaves identically, showing
  // the refusal doesn't depend on the cookie being absent vs. present-but-
  // ignored -- it's the missing `?secret=` and the wrong origin either way.
  const ctx2 = await browser.newContext();
  const controlPage = await ctx2.newPage();
  await controlPage.goto(attackerOrigin);
  await controlPage.waitForTimeout(1500);
  const controlResult = await controlPage.evaluate(() => window.result);
  assert.ok(!controlResult.events.some((e) => e.startsWith("message:")), "same refusal with no cookie at all");
  await ctx2.close();
});

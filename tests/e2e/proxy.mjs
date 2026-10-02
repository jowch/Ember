// A small reverse proxy standing in for Posit Workbench, JupyterHub's server
// proxy or VS Code port forwarding: it serves Ember under a path prefix, on
// a port of its own (never Ember's), and forwards everything underneath
// that prefix to Ember's real port with the prefix stripped -- the usual
// model for all three (the backend is never told what prefix it's mounted
// under, which is why every URL Ember itself builds has to be relative; see
// R/server.R's http_open() and http_index()). No npm dependency: plain
// `http` for requests, `net` for the raw TCP half of a websocket upgrade.

import http from "node:http";
import net from "node:net";

/** Start the proxy. `targetPort` is the real Ember server's port; `prefix`
 * is the path Ember is mounted under (e.g. "/s/abc/p/1", no trailing
 * slash). Requests outside `prefix` get 404, same as a real path-routing
 * proxy that knows nothing else is mounted there. Resolves to
 * `{ port, stop() }` once listening on 127.0.0.1. */
export function startReverseProxy(targetPort, prefix) {
  function forwardPath(url) {
    if (url === prefix) return "/";
    if (!url.startsWith(prefix + "/") && !url.startsWith(prefix + "?")) return null;
    const rest = url.slice(prefix.length);
    return rest.startsWith("/") ? rest : "/" + rest;
  }

  const server = http.createServer((req, res) => {
    const path = forwardPath(req.url);
    if (path === null) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("not found under this proxy's prefix");
      return;
    }
    const proxyReq = http.request(
      { host: "127.0.0.1", port: targetPort, method: req.method, path, headers: req.headers },
      (proxyRes) => {
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
        proxyRes.pipe(res);
      });
    proxyReq.on("error", (e) => {
      if (!res.headersSent) res.writeHead(502, { "Content-Type": "text/plain" });
      res.end("proxy error: " + e.message);
    });
    req.pipe(proxyReq);
  });

  // httpuv's websocket upgrade can't be proxied through `http.request`
  // (it never resolves a response for an upgraded connection), so the TCP
  // socket is connected directly and the request line/headers are
  // replayed onto it by hand, with the path rewritten the same way.
  server.on("upgrade", (req, clientSocket, head) => {
    const path = forwardPath(req.url);
    if (path === null) { clientSocket.destroy(); return; }

    const upstream = net.connect(targetPort, "127.0.0.1", () => {
      const lines = [`${req.method} ${path} HTTP/1.1`];
      for (const [name, value] of Object.entries(req.headers)) {
        const values = Array.isArray(value) ? value : [value];
        for (const v of values) lines.push(`${name}: ${v}`);
      }
      lines.push("", "");
      upstream.write(lines.join("\r\n"));
      if (head && head.length > 0) upstream.write(head);
      upstream.pipe(clientSocket);
      clientSocket.pipe(upstream);
    });
    upstream.on("error", () => clientSocket.destroy());
    clientSocket.on("error", () => upstream.destroy());
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      resolve({
        port: server.address().port,
        stop: () => server.close(),
      });
    });
  });
}

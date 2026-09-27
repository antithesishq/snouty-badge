#!/usr/bin/env node
// Cart watcher for the SYCL Badge web simulator (no npm dependencies).
//
//   node tools/serve-cart.mjs [path/to/cart.wasm] [--port 2468]
//
// The simulator (sycl-badge/simulator/src/ui/app.ts) fetches
// http://localhost:2468/cart.wasm and opens ws://localhost:2468/ws; when it
// receives the text message "reload" it re-fetches the cart. It sends "spam"
// every 100 ms as a keepalive, which we read and ignore.
//
// Default cart: zig-out/bin/snouty-bugs.wasm relative to the repo root. The file is
// polled every 500 ms; when its mtime or size changes, all clients get "reload".

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
let cartPath = path.join(repoRoot, "zig-out/bin/snouty-bugs.wasm");
let port = 2468;
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
    if (args[i] === "--port") port = Number(args[++i]);
    else if (args[i] === "-h" || args[i] === "--help") { console.log("usage: node tools/serve-cart.mjs [path/to/cart.wasm] [--port 2468]"); process.exit(0); }
    else if (args[i].startsWith("--")) { console.error(`serve-cart: unknown option ${args[i]}`); process.exit(2); }
    else cartPath = path.resolve(args[i]);
}
if (!Number.isInteger(port) || port <= 0 || port > 65535) { console.error("serve-cart: bad --port"); process.exit(2); }

const log = (m) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${m}`);
const baseHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "*",
    // Chrome Private Network Access: lets an https page (the hosted simulator) fetch localhost.
    "Access-Control-Allow-Private-Network": "true",
    "Cache-Control": "no-store",
};

function handleRequest(req, res) {
    const url = new URL(req.url, "http://localhost");
    if (req.method === "OPTIONS") { res.writeHead(204, baseHeaders); res.end(); return; }
    if ((req.method === "GET" || req.method === "HEAD") && url.pathname === "/cart.wasm") {
        fs.readFile(cartPath, (err, data) => {
            if (err) {
                res.writeHead(404, { ...baseHeaders, "Content-Type": "text/plain" });
                res.end(`cart not found: ${cartPath}\n`);
                log(`GET /cart.wasm -> 404 (${err.code})`);
                return;
            }
            res.writeHead(200, { ...baseHeaders, "Content-Type": "application/wasm", "Content-Length": data.length });
            res.end(req.method === "HEAD" ? undefined : data);
            log(`GET /cart.wasm -> 200 (${data.length} bytes)`);
        });
        return;
    }
    res.writeHead(404, { ...baseHeaders, "Content-Type": "text/plain" });
    res.end("not found\n");
}

// ------------------------------------------------------------ RFC 6455 WebSocket (server side)
const clients = new Set();
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function frame(opcode, payload) {
    const len = payload.length;
    let header;
    if (len < 126) header = Buffer.from([0x80 | opcode, len]);
    else if (len < 65536) { header = Buffer.alloc(4); header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(len, 2); }
    else { header = Buffer.alloc(10); header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(len), 2); }
    return Buffer.concat([header, payload]);
}

function handleUpgrade(req, socket) {
    const url = new URL(req.url, "http://localhost");
    const key = req.headers["sec-websocket-key"];
    if (url.pathname !== "/ws" || !key || (req.headers.upgrade || "").toLowerCase() !== "websocket") {
        socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
        return;
    }
    const accept = crypto.createHash("sha1").update(key + WS_GUID).digest("base64");
    socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.setNoDelay(true);
    clients.add(socket);
    log(`ws client connected (${clients.size} total)`);

    let buf = Buffer.alloc(0);
    socket.on("data", (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        for (;;) {
            if (buf.length < 2) return;
            const opcode = buf[0] & 0x0f, masked = buf[1] & 0x80;
            let len = buf[1] & 0x7f, off = 2;
            if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
            else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
            const maskOff = off; if (masked) off += 4;
            if (buf.length < off + len) return;
            const payload = Buffer.from(buf.subarray(off, off + len));
            if (masked) for (let i = 0; i < len; i++) payload[i] ^= buf[maskOff + (i & 3)];
            buf = buf.subarray(off + len);
            if (opcode === 0x8) { socket.end(frame(0x8, payload.subarray(0, 2))); return; } // close
            if (opcode === 0x9) socket.write(frame(0xa, payload)); // ping -> pong
            // text (0x1), binary (0x2), continuation (0x0), pong (0xa): ignored ("spam" keepalive)
        }
    });
    const drop = () => { if (clients.delete(socket)) log(`ws client disconnected (${clients.size} left)`); };
    socket.on("close", drop);
    socket.on("error", drop);
}

function broadcast(text) {
    const f = frame(0x1, Buffer.from(text, "utf8"));
    for (const s of clients) if (!s.destroyed) s.write(f);
}

// ------------------------------------------------------------ watch
const stamp = () => { try { const st = fs.statSync(cartPath); return `${st.mtimeMs}:${st.size}`; } catch { return null; } };
let last = stamp();
setInterval(() => {
    const now = stamp();
    if (now !== last) {
        last = now;
        if (now) { log(`cart changed, sending reload to ${clients.size} client(s)`); broadcast("reload"); }
        else log("cart file disappeared (waiting for rebuild)");
    }
}, 500);

// Listen on both loopback addresses: browsers may resolve "localhost" to
// either 127.0.0.1 or ::1. Not exposed to the network.
let listening = 0;
for (const host of ["127.0.0.1", "::1"]) {
    const server = http.createServer(handleRequest);
    server.on("upgrade", handleUpgrade);
    server.on("error", (e) => {
        if (host === "::1" && (e.code === "EADDRNOTAVAIL" || e.code === "EAFNOSUPPORT")) return; // no IPv6 loopback
        console.error(`serve-cart: ${host}:${port}: ${e.message}`); process.exit(1);
    });
    server.listen(port, host, () => {
        if (listening++ > 0) return;
        log(`serving ${cartPath}${last ? "" : " (does not exist yet)"}`);
        log(`http://localhost:${port}/cart.wasm  ws://localhost:${port}/ws`);
    });
}

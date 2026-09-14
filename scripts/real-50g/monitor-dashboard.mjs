#!/usr/bin/env node

import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { URL } from "node:url";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(process.env.REAL50G_ROOT ?? path.resolve(scriptDirectory, "../.."));
const resultsRoot = path.join(rootDir, "test-results");
const requestedRun = process.env.MONITOR_RUN_ID ?? process.argv[2] ?? "latest";
const bindAddress = process.env.MONITOR_BIND_ADDRESS || process.argv[3] || "0.0.0.0";
const port = Number(process.env.MONITOR_PORT ?? process.argv[4] ?? 18090);

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error(`invalid monitor port: ${port}`);
}

const html = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>fknat 实时监控</title>
  <style>
    :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }
    body { margin: 0; color: #172033; background: #f3f6fa; }
    main { max-width: 1280px; margin: 0 auto; padding: 24px; }
    header { display: flex; align-items: end; justify-content: space-between; gap: 16px; margin-bottom: 18px; }
    h1, h2, p { margin: 0; } h1 { font-size: 25px; } h2 { font-size: 16px; margin-bottom: 12px; }
    .muted { color: #657187; font-size: 13px; margin-top: 6px; }
    .state { padding: 6px 11px; border-radius: 6px; background: #d9f8e7; color: #08783f; font-weight: 700; }
    .state.down { background: #ffe2e2; color: #a11919; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 10px; margin-bottom: 14px; }
    .metric, section { background: #fff; border: 1px solid #dbe3ef; border-radius: 7px; }
    .metric { padding: 13px; } .metric span { display: block; color: #657187; font-size: 12px; } .metric strong { display: block; margin-top: 5px; font-size: 20px; }
    section { padding: 16px; margin-bottom: 14px; } .scroll { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; } th, td { padding: 8px 7px; text-align: left; border-bottom: 1px solid #e8edf3; white-space: nowrap; } th { color: #657187; font-weight: 600; }
    .ok { color: #08783f; font-weight: 700; } .warn { color: #9a5b00; font-weight: 700; } .bad { color: #a11919; font-weight: 700; }
    code { font-size: 12px; word-break: break-all; } select { max-width: 360px; padding: 6px 8px; border: 1px solid #c8d1df; border-radius: 5px; background: #fff; }
    @media (max-width: 640px) { main { padding: 14px; } header { align-items: start; flex-direction: column; } }
  </style>
</head>
<body>
  <main>
    <header><div><h1>fknat 实时监控</h1><p id="topology" class="muted">加载中...</p></div><div id="state" class="state">加载中</div></header>
    <section><h2>运行选择</h2><select id="runs" aria-label="运行选择"></select><p id="updated" class="muted"></p></section>
    <div class="grid" id="metrics"></div>
    <section><h2>节点进度</h2><div class="scroll"><table><thead><tr><th>节点</th><th>状态</th><th>已完成</th><th>文件</th><th>尝试</th><th>最近文件</th><th>退出码</th></tr></thead><tbody id="clients"></tbody></table></div></section>
    <section><h2>队列与服务</h2><div class="scroll"><table><thead><tr><th>队列/节点</th><th>深度</th><th>负载</th><th>文件</th><th>检查</th><th>服务</th><th>重启</th></tr></thead><tbody id="relays"></tbody></table></div></section>
    <section><h2>CA 与资源</h2><div class="scroll"><table><thead><tr><th>时间</th><th>源 HTTP</th><th>CA 公网</th><th>资源节点</th><th>当前内存</th><th>峰值内存</th><th>采集</th></tr></thead><tbody id="health"></tbody></table></div></section>
  </main>
  <script>
    const selected = ${JSON.stringify(requestedRun)};
    const $ = (id) => document.getElementById(id);
    const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : c === String.fromCharCode(34) ? "&quot;" : "&#39;");
    const bytes = (value) => { const n = Number(value) || 0; if (n >= 1073741824) return (n / 1073741824).toFixed(2) + " GiB"; if (n >= 1048576) return (n / 1048576).toFixed(2) + " MiB"; if (n >= 1024) return (n / 1024).toFixed(2) + " KiB"; return n + " B"; };
    const epoch = (value) => { const n = Number(value); return Number.isFinite(n) && n > 0 ? new Date(n * 1000).toLocaleString() : "-"; };
    const cls = (value) => value === "UP" || value === "PASS" || value === "running" ? "ok" : value === "DOWN" || value === "UNAVAILABLE" || value === "unavailable" ? "bad" : "warn";
    let activeRun = selected;
    async function loadRuns() {
      const response = await fetch("/api/runs"); const data = await response.json(); const select = $("runs");
      select.innerHTML = data.runs.map((run) => '<option value="' + esc(run.id) + '">' + esc(run.id) + ' (' + esc(run.phase) + ')</option>').join('');
      if (data.runs.some((run) => run.id === activeRun)) select.value = activeRun; else if (data.runs[0]) { activeRun = data.runs[0].id; select.value = activeRun; }
      select.onchange = () => { activeRun = select.value; loadStatus(); };
    }
    async function loadStatus() {
      const response = await fetch("/api/status?run=" + encodeURIComponent(activeRun)); const data = await response.json();
      const running = data.phase !== "complete" && data.phase !== "cleanup";
      $("state").textContent = data.phase + (data.reportResult ? " / " + data.reportResult : ""); $("state").className = "state" + (data.phase === "complete" && data.reportResult !== "PASS" ? " down" : "");
      $("topology").innerHTML = "本机 " + esc(data.topology.clientCount) + " NatClient → Client Relay (" + esc(data.topology.clientRelay) + ") → Server Relay (" + esc(data.topology.serverRelay) + ") → 本机 " + esc(data.topology.serverCount) + " NatServer · CA (" + esc(data.topology.ca) + ")";
      $("updated").textContent = "运行 " + data.runId + " · " + (running ? "运行中" : "已结束") + " · 更新 " + epoch(data.updatedEpoch);
      const metrics = [["阶段", data.phase], ["已验证", bytes(data.totalBytes)], ["当前在途", bytes(data.inflightBytes)], ["目标", bytes(data.expectedBytes)], ["完成比例", (data.expectedBytes ? (100 * data.totalBytes / data.expectedBytes).toFixed(2) : "0.00") + "%"], ["已完成文件", data.completedFiles + " / " + data.plannedFiles], ["CA 公网", data.ca.publicStatus], ["队列总深度", data.queueTotalDepth], ["最大重启", data.maxRestarts]];
      $("metrics").innerHTML = metrics.map(([label, value]) => '<div class="metric"><span>' + esc(label) + '</span><strong class="' + cls(value) + '">' + esc(value) + '</strong></div>').join('');
      $("clients").innerHTML = data.clients.length ? data.clients.map((item) => '<tr><td>' + esc(item.name) + '</td><td class="' + cls(item.status) + '">' + esc(item.status) + '</td><td>' + esc(item.successfulMiB) + ' MiB</td><td>' + esc(item.completedFiles) + ' / ' + esc(item.plannedFiles) + '</td><td>' + esc(item.attempts) + '</td><td>' + esc(item.lastFile || '-') + '</td><td>' + esc(item.exitCode) + '</td></tr>').join('') : '<tr><td colspan="7">暂无 Client 数据</td></tr>';
      $("relays").innerHTML = data.relays.map((item) => '<tr><td>' + esc(item.name) + '</td><td>' + esc(item.depth) + '</td><td>' + bytes(item.payloadBytes) + '</td><td>' + bytes(item.fileBytes) + '</td><td class="' + cls(item.inspectStatus) + '">' + esc(item.inspectStatus) + '</td><td class="' + cls(item.activeState) + '">' + esc(item.activeState) + '</td><td>' + esc(item.restarts) + '</td></tr>').join('') || '<tr><td colspan="7">暂无 Relay 数据</td></tr>';
      $("health").innerHTML = '<tr><td>' + epoch(data.ca.epoch) + '</td><td class="' + cls(data.ca.localStatus) + '">' + esc(data.ca.localStatus) + '</td><td class="' + cls(data.ca.publicStatus) + '">' + esc(data.ca.publicStatus) + '</td><td colspan="4">' + (data.resources.map((item) => esc(item.node) + ': ' + bytes(item.currentBytes) + ' / ' + bytes(item.peakBytes) + ' (' + esc(item.status) + ')').join(' · ') || '暂无资源数据') + '</td></tr>';
    }
    async function refresh() { try { await loadRuns(); await loadStatus(); } catch (error) { $("state").textContent = "读取失败"; $("state").className = "state down"; console.error(error); } }
    refresh(); setInterval(loadStatus, 5000); setInterval(loadRuns, 30000);
  </script>
</body>
</html>`;

function privateAddress() {
  for (const interfaces of Object.values(os.networkInterfaces())) {
    for (const item of interfaces ?? []) {
      if (item.family !== "IPv4" || item.internal) continue;
      const octets = item.address.split(".").map(Number);
      if (octets[0] === 10 || octets[0] === 192 && octets[1] === 168 || octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) return item.address;
    }
  }
  return "127.0.0.1";
}

function runDirectories() {
  try {
    return fs.readdirSync(resultsRoot, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => {
      const directory = path.join(resultsRoot, entry.name);
      let mtime = 0; try { mtime = fs.statSync(path.join(directory, "phase")).mtimeMs; } catch {}
      return { id: entry.name, directory, mtime, phase: readText(path.join(directory, "phase")).trim() || "unknown" };
    }).sort((left, right) => right.mtime - left.mtime);
  } catch { return []; }
}

function resolveRun(runId) {
  const runs = runDirectories();
  const wanted = !runId || runId === "latest" ? runs[0] : runs.find((run) => run.id === runId && path.basename(run.directory) === runId);
  return wanted ?? { id: runId || "latest", directory: "", phase: "missing", mtime: 0 };
}

function readText(filename) { try { return fs.readFileSync(filename, "utf8"); } catch { return ""; } }
function readEnv(filename) { return Object.fromEntries(readText(filename).split(/\r?\n/).filter((line) => line.includes("=")).map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)])); }
function readTSV(filename) { const text = readText(filename).trim(); if (!text) return []; const lines = text.split(/\r?\n/); const header = lines.shift().split("\t"); return lines.filter(Boolean).map((line) => Object.fromEntries(line.split("\t").map((value, index) => [header[index], value]))); }
function numeric(value, fallback = 0) { const result = Number(value); return Number.isFinite(result) ? result : fallback; }
function latestBy(rows, key) { const result = new Map(); for (const row of rows) result.set(row[key], row); return [...result.values()]; }
function latestDataMtime(directory) {
  let latest = 0;
  const candidates = ["phase", "queues.tsv", "restarts.tsv", "relay-resources.tsv", "ca-health.tsv"];
  for (const filename of candidates) { try { latest = Math.max(latest, fs.statSync(path.join(directory, filename)).mtimeMs); } catch {} }
  try {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (!entry.isDirectory() || !/^client-\d+$/.test(entry.name)) continue;
      for (const filename of ["progress.env", "summary.env", "transfers.tsv", "worker.exit"]) { try { latest = Math.max(latest, fs.statSync(path.join(directory, entry.name, filename)).mtimeMs); } catch {} }
    }
  } catch {}
  return latest;
}

function inflightBytes(directory) {
  let total = 0;
  try {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (!entry.isDirectory() || !entry.name.startsWith(".workers.")) continue;
      const workerDirectory = path.join(directory, entry.name);
      for (const file of fs.readdirSync(workerDirectory, { withFileTypes: true })) {
        if (!file.isFile() || !file.name.endsWith(".bin")) continue;
        try { total += fs.statSync(path.join(workerDirectory, file.name)).size; } catch {}
      }
    }
  } catch {}
  return total;
}

function transferProgress(transfers, progress) {
  const passed = transfers.filter((row) => row.status === "PASS");
  if (passed.length === 0) {
    return {
      successfulMiB: numeric(progress.successful_mib),
      completedFiles: numeric(progress.successful_files),
    };
  }
  return {
    successfulMiB: passed.reduce((sum, row) => sum + numeric(row.size_mib), 0),
    completedFiles: passed.length,
  };
}

function statusFor(run) {
  if (!run.directory) return { runId: run.id, phase: "missing", updatedEpoch: 0, clients: [], relays: [], resources: [], ca: { localStatus: "DOWN", publicStatus: "DOWN" }, topology: { ca: "https://ca.fknat.top", clientRelay: "-", serverRelay: "-", clientCount: 0, serverCount: 0 } };
  const metadata = readEnv(path.join(run.directory, "metadata.env"));
  const expectedBytes = numeric(metadata.total_bytes, 50 * 1024 ** 3);
  const clients = [];
  for (let index = 1; index <= 10; index += 1) {
    const name = "client-" + String(index).padStart(2, "0"); const directory = path.join(run.directory, name); if (!fs.existsSync(directory)) continue;
    const progress = readEnv(path.join(directory, "progress.env")); const summary = readEnv(path.join(directory, "summary.env")); const plan = readTSV(path.join(run.directory, "plans", name + ".tsv")); const transfers = readTSV(path.join(directory, "transfers.tsv")); const preflight = readTSV(path.join(directory, "preflight.tsv"))[0] ?? {};
    const transferSummary = transferProgress(transfers, progress);
    const status = summary.status || (fs.existsSync(path.join(directory, "complete")) ? "PASS" : run.phase === "workload" && preflight.status === "PASS" ? "RUNNING" : preflight.status === "PASS" ? "PREFLIGHT_PASS" : "RUNNING");
    clients.push({ name, status, successfulMiB: transferSummary.successfulMiB, completedFiles: transferSummary.completedFiles, plannedFiles: plan.length, attempts: numeric(progress.attempts) || transfers.length, lastFile: progress.last_file || "", exitCode: readText(path.join(directory, "worker.exit")).trim() || "-", inflightBytes: 0 });
  }
  const queues = latestBy(readTSV(path.join(run.directory, "queues.tsv")), "node");
  const restarts = latestBy(readTSV(path.join(run.directory, "restarts.tsv")), "unit");
  const relayUnits = new Map(restarts.map((row) => [row.node, row]));
  const relays = queues.map((row) => { const unit = relayUnits.get(row.node) ?? {}; return { name: row.node, depth: numeric(row.depth, -1), payloadBytes: numeric(row.payload_bytes), fileBytes: numeric(row.file_bytes), inspectStatus: row.inspect_status || "UNAVAILABLE", activeState: unit.active_state || "unavailable", restarts: numeric(unit.nrestarts, -1) }; });
  const resourceRows = latestBy(readTSV(path.join(run.directory, "relay-resources.tsv")), "node");
  const healthRows = readTSV(path.join(run.directory, "ca-health.tsv")); const health = healthRows.at(-1) ?? {};
  const totalBytes = clients.reduce((sum, client) => sum + client.successfulMiB * 1024 * 1024, 0);
  const currentInflightBytes = inflightBytes(run.directory);
  const queueTotalDepth = relays.every((relay) => relay.depth >= 0) ? relays.reduce((sum, relay) => sum + relay.depth, 0) : -1;
  const completedFiles = clients.reduce((sum, client) => sum + client.completedFiles, 0); const plannedFiles = clients.reduce((sum, client) => sum + client.plannedFiles, 0);
  const reportResult = readEnv(path.join(run.directory, "report-status.env")).result || "";
  return { runId: run.id, phase: run.phase, reportResult, updatedEpoch: Math.floor(Math.max(run.mtime, latestDataMtime(run.directory)) / 1000), expectedBytes, totalBytes, inflightBytes: currentInflightBytes, completedFiles, plannedFiles, queueTotalDepth, maxRestarts: Math.max(0, ...restarts.map((row) => numeric(row.nrestarts))), clients, relays, resources: resourceRows.map((row) => ({ node: row.node, currentBytes: numeric(row.memory_current_bytes), peakBytes: numeric(row.memory_peak_bytes), status: row.status || "UNAVAILABLE" })), ca: { epoch: numeric(health.epoch), localStatus: health.local_status || "DOWN", publicStatus: health.public_status || "DOWN" }, topology: { ca: metadata.ca_address || "https://ca.fknat.top", clientRelay: metadata.client_relay_address || "-", serverRelay: metadata.server_relay_address || "-", clientCount: numeric(metadata.client_count, clients.length), serverCount: numeric(metadata.server_count, 0) } };
}

function sendJSON(response, value) { const body = JSON.stringify(value); response.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "content-length": Buffer.byteLength(body) }); response.end(body); }
const server = http.createServer((request, response) => {
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
  if (request.method !== "GET") { response.writeHead(405); response.end("method not allowed"); return; }
  if (url.pathname === "/") { response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }); response.end(html); return; }
  if (url.pathname === "/api/runs") { sendJSON(response, { runs: runDirectories().map(({ id, phase, mtime }) => ({ id, phase, updatedEpoch: Math.floor(mtime / 1000) })) }); return; }
  if (url.pathname === "/api/status") { sendJSON(response, statusFor(resolveRun(url.searchParams.get("run") ?? requestedRun))); return; }
  response.writeHead(404); response.end("not found");
});

server.listen(port, bindAddress, () => process.stdout.write(`monitor dashboard listening at http://${bindAddress}:${port}/\n`));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
process.on("SIGINT", () => server.close(() => process.exit(0)));

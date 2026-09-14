import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const outputDirectory = path.resolve(process.argv[2] ?? "");
const specifications = process.argv.slice(3);
if (!process.argv[2] || outputDirectory === path.parse(outputDirectory).root || specifications.length === 0) {
  throw new Error("usage: generate-suite-report.mjs OUTPUT_DIR LABEL=RUN_DIR [...]");
}

const runs = specifications.map((specification) => {
  const separator = specification.indexOf("=");
  if (separator <= 0) throw new Error(`invalid run specification: ${specification}`);
  return inspectRun(specification.slice(0, separator), path.resolve(specification.slice(separator + 1)));
});

const qualified = runs.filter((run) => run.preflightPasses === 10 && run.preflightMaxSeconds > 0);
const fastest = qualified.sort((left, right) => right.aggregateMiBps - left.aggregateMiBps)[0];
const projectedHours = fastest ? 51200 / fastest.aggregateMiBps / 3600 : 0;
const formalBytes = runs.reduce((total, run) => total + run.formalBytes, 0);
const generated = new Date().toISOString();
const conclusion = formalBytes === 50 * 1024 ** 3 ? "PASS" : "FAIL";

const markdown = `# fknat 真实公网 50 GiB 测试汇总报告

- 结论：**${conclusion}**
- 拓扑：CA Web \`https://ca.fknat.top\`；Index \`193.112.62.9:9000\`；Client Relay \`160.202.47.24:9000\`；Server Relay \`198.2.237.123:8820\`
- 容器规模：10 个 NatClient、5 个 NatServer
- 目标载荷：50 GiB（每 Client 5 GiB；正式文件 100–200 MiB；逐文件 SHA-256）
- CA 故障计划：正式载荷期间每 10 分钟随机下线 3–5 分钟
- 正式已验证载荷：${formatBytes(formalBytes)} / 50.00 GiB
- 最快稳定预检：${fastest ? `${fastest.label}，10/10 通过，聚合 ${fastest.aggregateMiBps.toFixed(2)} MiB/s` : "无"}
- 按最快稳定预检外推：${fastest ? `${projectedHours.toFixed(1)} 小时完成 50 GiB` : "无法外推"}

## 结论说明

正常 KCP/TCP 双路模式无法让 10 个 Client 全部通过 16 MiB 预检，出现 KCP ACK 无进展和会话回收。Client/Server 端点改为 TCP fallback 后可稳定完成 10/10 预检及 SHA-256 校验，但最快一轮仍仅约 ${fastest?.aggregateMiBps.toFixed(2) ?? "0.00"} MiB/s，远低于 3 小时内完成 50 GiB 所需的 4.74 MiB/s；100–200 MiB 正式文件还会接近或超过原 900 秒单文件期限。

扩大单消息到 256 KiB、强制单 TCP leg、强制 Relay 间 TCP，以及把在途窗口扩大到 256，分别导致 ACK 重传耗尽、吞吐下降或预检超时。因此没有把这些不稳定参数用于正式载荷，也没有把 0 字节结果描述为 50 GiB 测试成功。由于正式载荷未启动，CA 周期下线与 waitSubmit 排空条件没有进入最终验收。

## 对照运行

| 运行 | 端点 / Relay 模式 | Chunk / 流窗口 / 计费槽 | 预检 | 预检耗时 | 聚合吞吐 | 50 GiB 外推 | 正式载荷 | 关键事件 |
|---|---|---:|---:|---:|---:|---:|---:|---|
${runs.map(markdownRow).join("\n")}

## 验收状态

| 条件 | 状态 |
|---|---|
| 10 Client / 5 Server 公网拓扑启动 | PASS |
| 10 个 Client 全部完成 16 MiB SHA-256 预检 | PASS（TCP fallback 对照） |
| 正常 KCP/TCP 双路通过全部预检 | FAIL |
| 正式 50 GiB 完整传输 | NOT RUN（资格预检带宽不足） |
| 每 Client 5 GiB | NOT RUN |
| 正式文件 100–200 MiB 且 SHA-256 一致 | 计划生成 PASS；正式传输 NOT RUN |
| CA 每 10 分钟下线 3–5 分钟且传输连续 | NOT RUN |
| waitSubmit 最终排空 | NOT RUN |

## 建议

在执行 50 GiB 前，先解决 160↔198 / Relay 端到端 ACK 数据路径的聚合吞吐瓶颈，并用 10×100 MiB 资格测试达到至少 5 MiB/s、连续 30 分钟无 ACK 重传耗尽。达到该门槛后再启用正式 50 GiB 和 CA 周期下线，才能在合理窗口内得到有效验收结果。

报告生成时间：${generated}
`;

fs.mkdirSync(outputDirectory, { recursive: true, mode: 0o700 });
fs.writeFileSync(path.join(outputDirectory, "report.md"), markdown, "utf8");
fs.writeFileSync(path.join(outputDirectory, "report.html"), renderHTML(runs, {
  conclusion, formalBytes, fastest, projectedHours, generated,
}), "utf8");
process.stdout.write(`${path.join(outputDirectory, "report.md")}\n${path.join(outputDirectory, "report.html")}\n`);

function inspectRun(label, directory) {
  const metadata = readEnv(path.join(directory, "metadata.env"));
  const status = readEnv(path.join(directory, "report-status.env"));
  const preflights = [];
  let partialBytes = 0;
  for (let index = 1; index <= 10; index += 1) {
    const clientDirectory = path.join(directory, `client-${String(index).padStart(2, "0")}`);
    const row = readTSV(path.join(clientDirectory, "preflight.tsv"))[0];
    if (row?.status === "PASS") preflights.push(number(row.duration_seconds));
    try { partialBytes += fs.statSync(path.join(clientDirectory, "preflight.bin")).size; } catch {}
  }
  const logs = collectLogs(directory);
  const preflightMaxSeconds = preflights.length ? Math.max(...preflights) : 0;
  const preflightMinSeconds = preflights.length ? Math.min(...preflights) : 0;
  return {
    label,
    directory,
    metadata,
    preflightPasses: preflights.length,
    preflightMinSeconds,
    preflightMaxSeconds,
    aggregateMiBps: preflights.length === 10 && preflightMaxSeconds > 0 ? 160 / preflightMaxSeconds : 0,
    formalBytes: number(status.total_bytes),
    partialBytes,
    ackExhausted: countMatches(logs, /ACK 重传耗尽/g),
    registrationRaces: countMatches(logs, /source_registration_required/g),
  };
}

function transport(run) {
  const endpoint = run.metadata.endpoint_transport === "tcp-only" ? "端点 TCP fallback" : "端点 KCP/TCP 双路";
  const relay = run.metadata.relay_disable_kcp === "1" ? "Relay TCP" : "Relay 双路";
  const single = run.metadata.endpoint_single_tcp === "1" ? "，单 leg" : "";
  return `${endpoint}${single}；${relay}`;
}

function tuning(run) {
  return `${run.metadata.tunnel_max_chunk ?? "65536"} / ${run.metadata.tunnel_stream_send_window ?? "32"} / ${run.metadata.max_pending_billing_data_sends ?? "16"}`;
}

function eventSummary(run) {
  const events = [];
  if (run.ackExhausted) events.push(`ACK耗尽 ${run.ackExhausted}`);
  if (run.registrationRaces) events.push(`注册竞态 ${run.registrationRaces}`);
  if (run.partialBytes) events.push(`未完成预检 ${formatBytes(run.partialBytes)}`);
  return events.join("；") || "无关键错误";
}

function markdownRow(run) {
  const duration = run.preflightPasses ? `${run.preflightMinSeconds}–${run.preflightMaxSeconds}s` : "-";
  const projection = run.aggregateMiBps > 0 ? `${(51200 / run.aggregateMiBps / 3600).toFixed(1)}h` : "-";
  return `| ${escapeMarkdown(run.label)} | ${escapeMarkdown(transport(run))} | ${tuning(run)} | ${run.preflightPasses}/10 | ${duration} | ${run.aggregateMiBps.toFixed(2)} MiB/s | ${projection} | ${formatBytes(run.formalBytes)} | ${escapeMarkdown(eventSummary(run))} |`;
}

function renderHTML(runsToRender, summary) {
  const rows = runsToRender.map((run) => `<tr><td>${h(run.label)}</td><td>${h(transport(run))}</td><td>${h(tuning(run))}</td><td>${run.preflightPasses}/10</td><td>${run.preflightPasses ? `${run.preflightMinSeconds}–${run.preflightMaxSeconds}s` : "-"}</td><td>${run.aggregateMiBps.toFixed(2)} MiB/s</td><td>${run.aggregateMiBps > 0 ? `${(51200 / run.aggregateMiBps / 3600).toFixed(1)}h` : "-"}</td><td>${h(formatBytes(run.formalBytes))}</td><td>${h(eventSummary(run))}</td></tr>`).join("");
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>fknat 真实公网 50 GiB 测试汇总报告</title><style>body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;background:#f4f7fb;color:#172033}main{max-width:1240px;margin:30px auto;padding:0 20px}.hero,.card{background:#fff;border:1px solid #dbe3ef;border-radius:14px;padding:22px;margin-bottom:18px;box-shadow:0 6px 22px rgba(30,55,90,.06)}h1,h2{margin-top:0}.result{display:inline-block;padding:7px 13px;border-radius:999px;font-weight:700;background:#ffe0e0;color:#a11919}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}.metric{background:#f7f9fd;border-radius:10px;padding:13px}.metric b{display:block;font-size:1.15rem;margin-top:4px}table{width:100%;border-collapse:collapse;font-size:.88rem}th,td{border-bottom:1px solid #e3e8f1;padding:9px;text-align:left;white-space:nowrap}.scroll{overflow:auto}.muted{color:#667085}</style></head><body><main><section class="hero"><span class="result">${h(summary.conclusion)}</span><h1>fknat 真实公网 50 GiB 测试汇总</h1><p>CA 129.28.42.247:4006 · Index 193.112.62.9:9000 · Client Relay 160.202.47.24:9000 · Server Relay 198.2.237.123:8820 · 10 Client / 5 Server</p><div class="grid"><div class="metric">正式已验证载荷<b>${h(formatBytes(summary.formalBytes))} / 50.00 GiB</b></div><div class="metric">最快稳定预检<b>${h(summary.fastest ? `${summary.fastest.aggregateMiBps.toFixed(2)} MiB/s` : "无")}</b></div><div class="metric">50 GiB 外推<b>${summary.fastest ? `${summary.projectedHours.toFixed(1)} 小时` : "-"}</b></div></div></section><section class="card"><h2>结论</h2><p>正常双路无法通过全部预检；TCP fallback 可 10/10 完成 SHA-256 校验，但公网 Relay 数据路径吞吐不足。正式 50 GiB、CA 周期下线和队列排空验收未启动，不能判定为成功。</p></section><section class="card"><h2>对照运行</h2><div class="scroll"><table><thead><tr><th>运行</th><th>传输模式</th><th>Chunk/流窗/计费槽</th><th>预检</th><th>耗时</th><th>聚合吞吐</th><th>50 GiB 外推</th><th>正式载荷</th><th>关键事件</th></tr></thead><tbody>${rows}</tbody></table></div></section><section class="card"><h2>建议</h2><p>先让 10×100 MiB 资格测试达到至少 5 MiB/s，并连续 30 分钟无 ACK 重传耗尽，再执行 50 GiB 与 CA 每 10 分钟下线 3–5 分钟的正式验收。</p></section><p class="muted">生成时间 ${h(summary.generated)}。报告不包含扣费私钥、CA Token 或数据库凭据。</p></main></body></html>`;
}

function readTSV(filename) {
  const text = readText(filename).trim();
  if (!text) return [];
  const lines = text.split(/\r?\n/);
  const header = lines.shift().split("\t");
  return lines.filter(Boolean).map((line) => Object.fromEntries(line.split("\t").map((value, index) => [header[index], value])));
}
function readEnv(filename) { return Object.fromEntries(readText(filename).split(/\r?\n/).filter((line) => line.includes("=")).map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)])); }
function readText(filename) { try { return fs.readFileSync(filename, "utf8"); } catch { return ""; } }
function number(value) { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; }
function collectLogs(directory) { const chunks = []; walk(directory, chunks); return chunks.join("\n"); }
function walk(directory, chunks) { if (!fs.existsSync(directory)) return; for (const entry of fs.readdirSync(directory, { withFileTypes: true })) { const filename = path.join(directory, entry.name); if (entry.isDirectory()) walk(filename, chunks); else if (/\.log$/.test(entry.name) && fs.statSync(filename).size < 128 * 1024 * 1024) chunks.push(readText(filename)); } }
function countMatches(text, expression) { return [...text.matchAll(expression)].length; }
function formatBytes(value) { if (value >= 1024 ** 3) return `${(value / 1024 ** 3).toFixed(2)} GiB`; if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(2)} MiB`; if (value >= 1024) return `${(value / 1024).toFixed(2)} KiB`; return `${value} B`; }
function escapeMarkdown(value) { return String(value).replace(/\|/g, "\\|").replace(/`/g, "\\`"); }
function h(value) { return String(value).replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]); }

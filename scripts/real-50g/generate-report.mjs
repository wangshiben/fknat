import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = path.resolve(process.argv[2] ?? "");
if (!process.argv[2] || root === path.parse(root).root) throw new Error("results directory is required");

const metadata = readEnv(path.join(root, "metadata.env"));
const plans = [];
const transfers = [];
const clients = [];
for (let index = 1; index <= 10; index += 1) {
  const client = `client-${String(index).padStart(2, "0")}`;
  const plan = readTSV(path.join(root, "plans", `${client}.tsv`));
  const rows = readTSV(path.join(root, client, "transfers.tsv"));
  plans.push(...plan.map((row) => ({ ...row, client })));
  transfers.push(...rows);
  const passing = rows.filter((row) => row.status === "PASS");
  clients.push({
    client,
    server: `server-${String(Math.ceil(index / 2)).padStart(2, "0")}`,
    plannedMiB: sum(plan, (row) => number(row.size_mib)),
    files: plan.length,
    passed: passing.length,
    attempts: rows.length,
    bytes: sum(passing, (row) => number(row.received_bytes)),
    retries: rows.length - passing.length,
    preflight: readTSV(path.join(root, client, "preflight.tsv"))[0]?.status ?? "MISSING",
    exit: readText(path.join(root, client, "worker.exit")).trim() || "missing",
  });
}

const passes = transfers.filter((row) => row.status === "PASS");
const failures = transfers.filter((row) => row.status !== "PASS");
const totalBytes = sum(passes, (row) => number(row.received_bytes));
const expectedBytes = 50 * 1024 * 1024 * 1024;
const planBytes = sum(plans, (row) => number(row.size_mib) * 1024 * 1024);
const sizesValid = plans.every((row) => number(row.size_mib) >= 100 && number(row.size_mib) <= 200);
const hashesValid = passes.every((row) => /^[0-9a-f]{64}$/.test(row.expected_sha ?? "") && row.expected_sha === row.actual_sha);
const uniqueCompleted = new Set(passes.map((row) => `${row.client}/${row.file_index}`)).size;
const plannedFiles = plans.length;
const speeds = passes.map((row) => number(row.speed_bps)).filter((value) => value > 0).sort((a, b) => a - b);
const starts = passes.map((row) => number(row.started_epoch)).filter(Boolean);
const finishes = passes.map((row) => number(row.finished_epoch)).filter(Boolean);
const createdEpoch = number(metadata.created_epoch);
const workloadStart = number(metadata.workload_start_epoch) || minimumValue(starts) || createdEpoch;
const workloadFinish = number(metadata.workload_finished_epoch) || maximumValue(finishes) || workloadStart;
const workloadSeconds = Math.max(1, workloadFinish - workloadStart);
const overallBps = totalBytes / workloadSeconds;
const endpointTransport = metadata.endpoint_transport === "tcp-only"
  ? "TCP fallback（Client/Server 端点禁用 KCP；Relay 仍保留 KCP）"
  : "KCP/TCP 双路自动故障转移";
const relayTransport = metadata.relay_disable_kcp === "1"
  ? "Relay 间 TCP fallback（193→198 TCP 经受限 SSH 转发）"
  : "Relay 间保留 KCP/TCP 双路";

const outages = readTSV(path.join(root, "ca-outages.tsv"));
const outageAnalysis = outages.map((outage) => {
  const down = number(outage.public_unavailable_epoch || outage.down_epoch);
  const up = number(outage.recovered_epoch);
  const overlapping = passes.filter((row) => number(row.started_epoch) < up && number(row.finished_epoch) > down);
  const contained = passes.filter((row) => number(row.started_epoch) >= down && number(row.finished_epoch) <= up);
  return { ...outage, actualSeconds: up > number(outage.down_epoch) ? up - number(outage.down_epoch) : 0, overlapping: overlapping.length, contained: contained.length };
});
const expectedOutages = Math.floor(workloadSeconds / 600);
const outageValid = outageAnalysis.length >= expectedOutages
  && outageAnalysis.every((item) => item.status === "PASS" && item.actualSeconds >= 180 && item.actualSeconds <= 330);
const outageContinuity = outageAnalysis.every((item) => item.overlapping > 0);

const queues = readTSV(path.join(root, "queues.tsv"));
const peakQueueDepth = maximum(queues, (row) => number(row.depth));
const peakQueueBytes = maximum(queues, (row) => number(row.payload_bytes));
const drain = readTSV(path.join(root, "queue-drain.tsv"));
const finalQueueDepth = drain.length ? number(drain[drain.length - 1].total_depth) : -1;
const drainSeconds = drain.length ? number(drain[drain.length - 1].elapsed_seconds) : -1;

const billingBefore = mapBy(readTSV(path.join(root, "billing-before.tsv")), "user_id");
const billingAfter = mapBy(readTSV(path.join(root, "billing-after.tsv")), "user_id");
const billing = [...billingAfter.entries()].map(([user, after]) => {
  const before = billingBefore.get(user) ?? {};
  return {
    user,
    balanceBefore: number(before.balance_bytes),
    balanceAfter: number(after.balance_bytes),
    userConsumedDelta: number(after.user_consumed_bytes) - number(before.user_consumed_bytes),
    authConsumedDelta: number(after.authorization_consumed_bytes) - number(before.authorization_consumed_bytes),
    authEarnedDelta: number(after.authorization_earned_bytes) - number(before.authorization_earned_bytes),
    authorizations: number(after.authorization_count),
    certificates: number(after.certificate_count),
  };
});

const logs = collectLogs(root);
const events = {
  kcp: countMatches(logs, /\bKCP\b/gi),
  tcp: countMatches(logs, /\bTCP\b/gi),
  resume: countMatches(logs, /Resume|恢复会话|续传/gi),
  generation: countMatches(logs, /generation|代次/gi),
  vouchersSubmitted: countMatches(logs, /双签凭证已提交/gi),
  waitSubmitUnavailable: countMatches(logs, /waitSubmit 无法访问 CA/gi),
  caRejected: countMatches(logs, /凭证被 CA 拒绝|CA.*拒绝/gi),
};

const restartRows = readTSV(path.join(root, "restarts.tsv"));
const maximumRestarts = maximum(restartRows, (row) => Math.max(0, number(row.nrestarts)));
const integrityFailures = failures.filter((row) => row.status === "SHA_FAILED" || row.status === "SIZE_FAILED").length;
const clientPass = clients.every((client) => client.plannedMiB === 5120 && client.bytes === 5120 * 1024 * 1024
  && client.passed === client.files && client.preflight === "PASS" && client.exit === "0");
const pass = planBytes === expectedBytes && totalBytes === expectedBytes && uniqueCompleted === plannedFiles
  && sizesValid && hashesValid && clientPass && integrityFailures === 0 && outageValid && outageContinuity
  && finalQueueDepth === 0 && events.caRejected === 0 && maximumRestarts === 0;

const result = pass ? "PASS" : "FAIL";
const generated = new Date().toISOString();
const markdown = `# fknat 真实公网 50 GiB 多节点传输测试报告

- 结论：**${result}**
- 运行 ID：\`${escapeMarkdown(metadata.run_id ?? path.basename(root))}\`
- 测试时间：${formatEpoch(workloadStart)} — ${formatEpoch(workloadFinish)}（${formatDuration(workloadSeconds)}）
- 拓扑：CA Web 经 \`129.28.42.247:4006\` FRP 暴露；Client Relay \`193.112.62.9:9000\`；Server Relay \`198.2.237.123:8820\`。193 Relay 与测试容器访问 Server Relay 时，UDP/KCP 直连 198，只有 TCP 8820 分别经本机→198 与 193→198 的临时受限 SSH 转发
- 端点传输模式：${endpointTransport}
- Relay 间传输模式：${relayTransport}
- fknat SHA-256：\`${escapeMarkdown(metadata.fknat_sha256 ?? "unknown")}\`
- nodeserver SHA-256：\`${escapeMarkdown(metadata.nodeserver_sha256 ?? "unknown")}\`

## 核心结果

| 指标 | 结果 |
|---|---:|
| 计划有效载荷 | ${formatBytes(expectedBytes)} |
| 已验证有效载荷 | ${formatBytes(totalBytes)} |
| 成功文件 / 计划文件 | ${uniqueCompleted} / ${plannedFiles} |
| 文件范围断言 | ${sizesValid ? "PASS" : "FAIL"}（100–200 MiB） |
| SHA-256 断言 | ${hashesValid ? "PASS" : "FAIL"} |
| 重试前失败尝试 | ${failures.length}（完整性失败 ${integrityFailures}） |
| 整体平均有效吞吐 | ${formatRate(overallBps)} |
| 单文件 P50 / P95 / 峰值 | ${formatRate(percentile(speeds, 0.50))} / ${formatRate(percentile(speeds, 0.95))} / ${formatRate(maximumValue(speeds))} |
| CA 下线次数 | ${outageAnalysis.length}（按负载时长应触发 ${expectedOutages} 次） |
| CA 下线期间持续传输 | ${outageContinuity ? "PASS" : "FAIL"} |
| waitSubmit 峰值 | ${peakQueueDepth} 张 / ${formatBytes(peakQueueBytes)} |
| waitSubmit 最终深度 | ${finalQueueDepth}（排空耗时 ${drainSeconds}s） |
| Relay/Index 最大重启数 | ${maximumRestarts} |

## Client 明细

| Client | Server | 计划 MiB | 文件 | 成功 | 尝试 | 重试 | 接收字节 | 预检 | 退出码 |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|
${clients.map((item) => `| ${item.client} | ${item.server} | ${item.plannedMiB} | ${item.files} | ${item.passed} | ${item.attempts} | ${item.retries} | ${item.bytes} | ${item.preflight} | ${item.exit} |`).join("\n")}

## CA 周期下线

| # | 计划下线 | 实际不可用 | 恢复 | 实际时长 | 重叠成功文件 | 完全位于下线期 | 状态 |
|---:|---|---|---|---:|---:|---:|---|
${outageAnalysis.length ? outageAnalysis.map((item) => `| ${item.sequence} | ${formatEpoch(number(item.scheduled_epoch))} | ${formatEpoch(number(item.public_unavailable_epoch))} | ${formatEpoch(number(item.recovered_epoch))} | ${item.actualSeconds}s | ${item.overlapping} | ${item.contained} | ${item.status} |`).join("\n") : "| - | - | - | - | - | - | - | MISSING |"}

## 计费与协议事件

| 用户 | 测试前余额 | 测试后余额 | 用户消耗增量 | 授权消耗增量 | 授权收益增量 | 授权数 | 证书数 |
|---|---:|---:|---:|---:|---:|---:|---:|
${billing.map((item) => `| ${item.user} | ${item.balanceBefore} | ${item.balanceAfter} | ${item.userConsumedDelta} | ${item.authConsumedDelta} | ${item.authEarnedDelta} | ${item.authorizations} | ${item.certificates} |`).join("\n")}

- KCP 日志事件：${events.kcp}
- TCP 日志事件：${events.tcp}
- Resume/恢复事件：${events.resume}
- Relay generation/代次事件：${events.generation}
- 已提交累计凭证：${events.vouchersSubmitted}
- CA 不可达时 waitSubmit 保留事件：${events.waitSubmitUnavailable}
- CA 拒绝事件：${events.caRejected}

## 判定规则

最终 PASS 要求：总量严格等于 50 GiB；每个 Client 严格完成 5 GiB；所有正式文件为 100–200 MiB 且 SHA-256 一致；允许可恢复的网络重试，但不允许 SHA/大小完整性失败；应触发的 CA 下线均为 3–5 分钟并恢复，且每个下线窗口都有成功传输重叠；waitSubmit 最终排空；无 CA 拒绝、容器或远端服务重启。

报告生成时间：${generated}
`;

fs.writeFileSync(path.join(root, "report.md"), markdown, "utf8");
fs.writeFileSync(path.join(root, "report.html"), renderHTML(markdown, {
  result, metadata, workloadStart, workloadFinish, workloadSeconds, expectedBytes, totalBytes,
  uniqueCompleted, plannedFiles, sizesValid, hashesValid, failures: failures.length, overallBps,
  p50: percentile(speeds, 0.50), p95: percentile(speeds, 0.95), peak: maximumValue(speeds), integrityFailures,
  clients, outageAnalysis, expectedOutages, outageContinuity, peakQueueDepth, peakQueueBytes,
  finalQueueDepth, drainSeconds, maximumRestarts, billing, events, generated,
}), "utf8");
fs.writeFileSync(path.join(root, "report-status.env"), `result=${result}\ntotal_bytes=${totalBytes}\nexpected_bytes=${expectedBytes}\nfiles=${uniqueCompleted}\noutages=${outageAnalysis.length}\n`, "utf8");
process.stdout.write(`report generated result=${result} bytes=${totalBytes} files=${uniqueCompleted} outages=${outageAnalysis.length}\n`);

function renderHTML(_markdown, data) {
  const clientRows = data.clients.map((item) => `<tr><td>${h(item.client)}</td><td>${h(item.server)}</td><td>${item.plannedMiB}</td><td>${item.files}</td><td>${item.passed}</td><td>${item.attempts}</td><td>${item.retries}</td><td>${h(formatBytes(item.bytes))}</td><td>${h(item.preflight)}</td><td>${h(item.exit)}</td></tr>`).join("");
  const outageRows = data.outageAnalysis.length ? data.outageAnalysis.map((item) => `<tr><td>${h(item.sequence)}</td><td>${h(formatEpoch(number(item.scheduled_epoch)))}</td><td>${h(formatEpoch(number(item.public_unavailable_epoch)))}</td><td>${h(formatEpoch(number(item.recovered_epoch)))}</td><td>${item.actualSeconds}s</td><td>${item.overlapping}</td><td>${item.contained}</td><td>${h(item.status)}</td></tr>`).join("") : `<tr><td colspan="8">MISSING</td></tr>`;
  const billingRows = data.billing.map((item) => `<tr><td>${h(item.user)}</td><td>${item.balanceBefore}</td><td>${item.balanceAfter}</td><td>${item.userConsumedDelta}</td><td>${item.authConsumedDelta}</td><td>${item.authEarnedDelta}</td><td>${item.authorizations}</td><td>${item.certificates}</td></tr>`).join("");
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>fknat 50 GiB 真实公网测试报告</title><style>body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;background:#f4f7fb;color:#172033}main{max-width:1180px;margin:32px auto;padding:0 20px}.hero,.card{background:#fff;border:1px solid #dbe3ef;border-radius:14px;padding:22px;margin-bottom:18px;box-shadow:0 6px 22px rgba(30,55,90,.06)}h1,h2{margin-top:0}.result{display:inline-block;padding:7px 13px;border-radius:999px;font-weight:700;background:${data.result === "PASS" ? "#d9f8e7;color:#08783f" : "#ffe0e0;color:#a11919"}}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px}.metric{background:#f7f9fd;border-radius:10px;padding:13px}.metric b{display:block;font-size:1.15rem;margin-top:4px}table{width:100%;border-collapse:collapse;font-size:.9rem}th,td{border-bottom:1px solid #e3e8f1;padding:9px;text-align:left;white-space:nowrap}.scroll{overflow:auto}code{word-break:break-all}.muted{color:#667085}</style></head><body><main><section class="hero"><span class="result">${h(data.result)}</span><h1>fknat 真实公网 50 GiB 多节点传输测试</h1><p class="muted">${h(formatEpoch(data.workloadStart))} — ${h(formatEpoch(data.workloadFinish))} · ${h(formatDuration(data.workloadSeconds))}</p><p>CA Web 经 129.28.42.247:4006 FRP 暴露；Client Relay 193.112.62.9:9000 → Server Relay 198.2.237.123:8820；UDP/KCP 直连 198，TCP 8820 分别经本机→198 与 193→198 的临时受限 SSH 转发</p><p>端点传输模式：${h(endpointTransport)}<br>Relay 间传输模式：${h(relayTransport)}</p><p><code>fknat ${h(data.metadata.fknat_sha256 ?? "unknown")}</code><br><code>nodeserver ${h(data.metadata.nodeserver_sha256 ?? "unknown")}</code></p></section><section class="card"><h2>核心结果</h2><div class="grid"><div class="metric">有效载荷<b>${h(formatBytes(data.totalBytes))} / ${h(formatBytes(data.expectedBytes))}</b></div><div class="metric">文件校验<b>${data.uniqueCompleted} / ${data.plannedFiles}</b></div><div class="metric">整体平均吞吐<b>${h(formatRate(data.overallBps))}</b></div><div class="metric">P50 / P95 / 峰值<b>${h(formatRate(data.p50))} / ${h(formatRate(data.p95))} / ${h(formatRate(data.peak))}</b></div><div class="metric">CA 下线<b>${data.outageAnalysis.length} / 应触发 ${data.expectedOutages}</b></div><div class="metric">waitSubmit 峰值/最终<b>${data.peakQueueDepth} / ${data.finalQueueDepth}</b></div><div class="metric">重试前失败 / 完整性失败<b>${data.failures} / ${data.integrityFailures}</b></div><div class="metric">最大服务重启<b>${data.maximumRestarts}</b></div></div></section><section class="card"><h2>Client 明细</h2><div class="scroll"><table><thead><tr><th>Client</th><th>Server</th><th>计划 MiB</th><th>文件</th><th>成功</th><th>尝试</th><th>重试</th><th>接收量</th><th>预检</th><th>退出</th></tr></thead><tbody>${clientRows}</tbody></table></div></section><section class="card"><h2>CA 周期下线</h2><div class="scroll"><table><thead><tr><th>#</th><th>计划</th><th>不可用</th><th>恢复</th><th>时长</th><th>重叠文件</th><th>完全位于窗口</th><th>状态</th></tr></thead><tbody>${outageRows}</tbody></table></div></section><section class="card"><h2>计费</h2><div class="scroll"><table><thead><tr><th>用户</th><th>测试前余额</th><th>测试后余额</th><th>用户消耗增量</th><th>授权消耗增量</th><th>授权收益增量</th><th>授权数</th><th>证书数</th></tr></thead><tbody>${billingRows}</tbody></table></div></section><section class="card"><h2>协议与队列事件</h2><div class="grid"><div class="metric">KCP / TCP<b>${data.events.kcp} / ${data.events.tcp}</b></div><div class="metric">Resume / generation<b>${data.events.resume} / ${data.events.generation}</b></div><div class="metric">累计凭证提交<b>${data.events.vouchersSubmitted}</b></div><div class="metric">CA 不可达保留<b>${data.events.waitSubmitUnavailable}</b></div><div class="metric">CA 拒绝<b>${data.events.caRejected}</b></div><div class="metric">队列排空耗时<b>${data.drainSeconds}s</b></div></div></section><p class="muted">生成时间 ${h(data.generated)}。报告不包含扣费私钥、CA 管理令牌或数据库凭据。</p></main></body></html>`;
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
function sum(values, mapper) { return values.reduce((total, value) => total + mapper(value), 0); }
function maximum(values, mapper) { return values.reduce((result, value) => Math.max(result, mapper(value)), 0); }
function minimumValue(values) { return values.length ? values[0] : 0; }
function maximumValue(values) { return values.length ? values[values.length - 1] : 0; }
function percentile(values, ratio) { if (!values.length) return 0; return values[Math.min(values.length - 1, Math.ceil(values.length * ratio) - 1)]; }
function mapBy(values, key) { return new Map(values.map((value) => [value[key], value])); }
function collectLogs(directory) { const chunks = []; walk(directory, chunks); return chunks.join("\n"); }
function walk(directory, chunks) { for (const entry of fs.readdirSync(directory, { withFileTypes: true })) { const filename = path.join(directory, entry.name); if (entry.isDirectory()) walk(filename, chunks); else if (/\.log$/.test(entry.name) && fs.statSync(filename).size < 128 * 1024 * 1024) chunks.push(readText(filename)); } }
function countMatches(text, expression) { return [...text.matchAll(expression)].length; }
function formatBytes(value) { if (value >= 1024 ** 3) return `${(value / 1024 ** 3).toFixed(2)} GiB`; if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(2)} MiB`; return `${value} B`; }
function formatRate(value) { return `${(value * 8 / 1e6).toFixed(2)} Mbit/s`; }
function formatDuration(seconds) { return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m ${seconds % 60}s`; }
function formatEpoch(epoch) { return epoch > 0 ? new Date(epoch * 1000).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false }) : "-"; }
function escapeMarkdown(value) { return String(value).replace(/`/g, "\\`"); }
function h(value) { return String(value).replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]); }

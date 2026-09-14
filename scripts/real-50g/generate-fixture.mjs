import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { execFileSync } from "node:child_process";

process.umask(0o077);

const [privateRootValue, resultsRootValue, caContainer = "ca_web-backend-1"] = process.argv.slice(2);
if (!privateRootValue || !resultsRootValue) {
  throw new Error("usage: generate-fixture.mjs PRIVATE_ROOT RESULTS_ROOT [CA_CONTAINER]");
}
const privateRoot = path.resolve(privateRootValue);
const resultsRoot = path.resolve(resultsRootValue);
if (privateRoot === path.parse(privateRoot).root || resultsRoot === path.parse(resultsRoot).root) {
  throw new Error("unsafe fixture path");
}
const clientCount = 10;
const totalMiB = Number.parseInt(process.env.REAL50G_TOTAL_MIB ?? "51200", 10);
if (!Number.isSafeInteger(totalMiB) || totalMiB < clientCount * 100 || totalMiB % clientCount !== 0) {
  throw new Error("REAL50G_TOTAL_MIB must divide evenly into 10 Client plans of at least 100 MiB");
}
const perClientMiB = totalMiB / clientCount;

const assignments = new Map([
  ["demo_user", Array.from({ length: clientCount }, (_, index) => `client-${pad(index + 1)}`)],
  ["developer", Array.from({ length: 5 }, (_, index) => `server-${pad(index + 1)}`)],
  ["observer", ["index", "relay-server", "relay-client"]],
]);

fs.mkdirSync(privateRoot, { recursive: true, mode: 0o700 });
fs.chmodSync(privateRoot, 0o700);
fs.mkdirSync(path.join(resultsRoot, "plans"), { recursive: true, mode: 0o755 });
fs.mkdirSync(path.join(resultsRoot, "control"), { recursive: true, mode: 0o755 });

const manifest = { version: 1, users: [] };
for (const [username, services] of assignments) {
  const bundle = createBundle(username);
  for (const service of services) {
    writePrivateJSON(path.join(privateRoot, service, "billing-key.json"), bundle);
    fs.mkdirSync(path.join(privateRoot, service), { recursive: true, mode: 0o700 });
    fs.chmodSync(path.join(privateRoot, service), 0o700);
  }
  manifest.users.push({
    username,
    user_id: `usr_mock_${username === "demo_user" ? "demo" : username}`,
    key_id: bundle.key_id,
    public_key_hex: bundle.public_key_hex,
    label: bundle.label,
    services,
  });
}
writePrivateJSON(path.join(privateRoot, "ca", "billing-key-bootstrap.json"), manifest);
writeCAEnvironment(caContainer, path.join(privateRoot, "ca", "backend.env"));

const planSummary = [];
for (let client = 1; client <= clientCount; client += 1) {
  const name = `client-${pad(client)}`;
  const sizes = generatePlan(perClientMiB);
  const lines = ["file_index\tsize_mib\tvariant"];
  sizes.forEach((size, index) => {
    lines.push(`${index + 1}\t${size}\t${name}-file-${String(index + 1).padStart(3, "0")}`);
  });
  writePublic(path.join(resultsRoot, "plans", `${name}.tsv`), `${lines.join("\n")}\n`);
  planSummary.push({ client: name, files: sizes.length, total_mib: sizes.reduce((sum, value) => sum + value, 0) });
}
writePublic(path.join(resultsRoot, "plan-summary.json"), `${JSON.stringify({
  version: 1,
  total_mib: totalMiB,
  total_bytes: totalMiB * 1024 * 1024,
  per_client_mib: perClientMiB,
  minimum_file_mib: 100,
  maximum_file_mib: 200,
  clients: planSummary,
}, null, 2)}\n`);

process.stdout.write(`fixture ready clients=${clientCount} servers=5 total_mib=${totalMiB} files=${planSummary.reduce((sum, item) => sum + item.files, 0)}\n`);

function createBundle(username) {
  const pair = crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const privateJWK = pair.privateKey.export({ format: "jwk" });
  const publicBytes = Buffer.concat([
    Buffer.from([4]),
    Buffer.from(privateJWK.x, "base64url"),
    Buffer.from(privateJWK.y, "base64url"),
  ]);
  return {
    version: 1,
    key_id: crypto.createHash("sha256").update(publicBytes).digest("hex"),
    label: `local-chaos-${username}`,
    algorithm: "ECDSA_P256_SHA256",
    private_key_jwk: privateJWK,
    public_key_hex: publicBytes.toString("hex"),
    charge_endpoint: "/api/v1/billing/charge",
    node_authorization_endpoint: "/v1/node/authorize",
    framework_environment: "BNFS_BILLING_KEY_FILE",
    canonical_format: "CA-BILLING-V1\\n{key_id}\\n{amount_bytes}\\n{unix_timestamp}\\n{nonce}\\n{reference}",
    registration_status: "pending",
    generated_at: new Date().toISOString(),
  };
}

function generatePlan(totalMiB) {
  const result = [];
  let remaining = totalMiB;
  while (remaining > 200) {
    const maximum = Math.min(200, remaining - 100);
    const size = crypto.randomInt(100, maximum + 1);
    result.push(size);
    remaining -= size;
  }
  if (remaining < 100 || remaining > 200) throw new Error("invalid final plan fragment");
  result.push(remaining);
  return result;
}

function writeCAEnvironment(container, filename) {
  const encoded = execFileSync("docker", ["inspect", container], {
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  const inspected = JSON.parse(encoded);
  const environment = inspected?.[0]?.Config?.Env;
  if (!Array.isArray(environment) || environment.length === 0) throw new Error("CA environment unavailable");
  const safeLines = environment.filter((line) => typeof line === "string" && !/[\r\n]/.test(line));
  writePrivate(filename, `${safeLines.join("\n")}\n`);
}

function writePrivateJSON(filename, value) {
  writePrivate(filename, `${JSON.stringify(value, null, 2)}\n`);
}

function writePrivate(filename, contents) {
  fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
  fs.chmodSync(path.dirname(filename), 0o700);
  const temporary = `${filename}.tmp-${process.pid}-${crypto.randomBytes(4).toString("hex")}`;
  fs.writeFileSync(temporary, contents, { mode: 0o600, flag: "wx" });
  fs.renameSync(temporary, filename);
  fs.chmodSync(filename, 0o600);
}

function writePublic(filename, contents) {
  fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o755 });
  fs.writeFileSync(filename, contents, { mode: 0o644 });
}

function pad(value) {
  return String(value).padStart(2, "0");
}

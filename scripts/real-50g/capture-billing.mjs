import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { execFileSync } from "node:child_process";

process.umask(0o077);

const [manifestValue, outputValue, postgresContainer = "ca_web-postgres-1"] = process.argv.slice(2);
if (!manifestValue || !outputValue) {
  throw new Error("usage: capture-billing.mjs MANIFEST OUTPUT [POSTGRES_CONTAINER]");
}
const manifest = JSON.parse(fs.readFileSync(path.resolve(manifestValue), "utf8"));
if (manifest?.version !== 1 || !Array.isArray(manifest.users) || manifest.users.length !== 3) {
  throw new Error("invalid billing manifest");
}
const values = manifest.users.map((user) => {
  if (!/^usr_mock_[a-z_]+$/.test(user.user_id) || !/^[0-9a-f]{64}$/.test(user.key_id)) {
    throw new Error("invalid billing selector");
  }
  return `('${user.user_id}','${user.key_id}')`;
}).join(",");

const sql = `COPY (
  WITH selected(user_id, key_id) AS (VALUES ${values})
  SELECT selected.user_id,
         COALESCE(account.balance_bytes, 0) AS balance_bytes,
         COALESCE(account.consumed_bytes, 0) AS user_consumed_bytes,
         COALESCE((SELECT sum(auth.consumed_bytes) FROM user_node_authorizations auth
                   WHERE auth.billing_key_id = selected.key_id), 0) AS authorization_consumed_bytes,
         COALESCE((SELECT sum(auth.earned_bytes) FROM user_node_authorizations auth
                   WHERE auth.billing_key_id = selected.key_id), 0) AS authorization_earned_bytes,
         COALESCE((SELECT count(*) FROM user_node_authorizations auth
                   WHERE auth.billing_key_id = selected.key_id), 0) AS authorization_count,
         COALESCE((SELECT count(*) FROM certificates cert
                   WHERE cert.billing_key_id = selected.key_id), 0) AS certificate_count,
         COALESCE((SELECT count(*) FROM billing_charge_requests request
                   WHERE request.key_id = selected.key_id), 0) AS direct_charge_count
  FROM selected
  LEFT JOIN user_accounts account ON account.user_id = selected.user_id
  ORDER BY selected.user_id
) TO STDOUT WITH (FORMAT csv, HEADER true, DELIMITER E'\\t');`;

const output = execFileSync("docker", ["exec", postgresContainer, "psql", "-v", "ON_ERROR_STOP=1",
  "-U", "ca_web", "-d", "ca_web", "-c", sql], {
  encoding: "utf8",
  maxBuffer: 4 * 1024 * 1024,
});
const filename = path.resolve(outputValue);
fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o755 });
fs.writeFileSync(filename, output, { mode: 0o644 });

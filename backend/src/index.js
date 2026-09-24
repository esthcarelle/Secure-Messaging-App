import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { createApp } from "./app.js";
import { createS3Client } from "./media.js";

loadLocalEnv();
const env = process.env;
const pool = new pg.Pool(databasePoolConfig(env.DATABASE_URL));
const schema = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../sql/schema.sql"), "utf8");

await pool.query(schema);
const app = createApp({ pool, s3: createS3Client(env), env });
const port = Number(env.PORT || 8080);
app.listen(port, "0.0.0.0", () => {
  console.log(`directory listening on ${port}`);
});

function loadLocalEnv() {
  const path = join(dirname(fileURLToPath(import.meta.url)), "../.env");
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq <= 0) continue;
    const key = trimmed.slice(0, eq).trim();
    if (process.env[key] !== undefined) continue;
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

function databasePoolConfig(connectionString) {
  const local = typeof connectionString === "string" && /(localhost|127\.0\.0\.1)/.test(connectionString);
  return {
    connectionString,
    ssl: local ? undefined : { rejectUnauthorized: false },
  };
}

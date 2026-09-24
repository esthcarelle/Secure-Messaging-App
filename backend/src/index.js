import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { createApp } from "./app.js";
import { createS3Client } from "./media.js";

const env = process.env;
const pool = new pg.Pool({ connectionString: env.DATABASE_URL });
const schema = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../sql/schema.sql"), "utf8");

await pool.query(schema);
const app = createApp({ pool, s3: createS3Client(env), env });
const port = Number(env.PORT || 8080);
app.listen(port, () => {
  console.log(`directory listening on ${port}`);
});

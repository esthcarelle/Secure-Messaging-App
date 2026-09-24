import express from "express";
import jwt from "jsonwebtoken";
import {
  decodePublicKey,
  hashPassword,
  HttpError,
  validateCredentials,
  verifyPassword,
} from "./auth.js";
import { createDownloadUrl, createUploadTicket } from "./media.js";

export function createApp({ pool, s3, env }) {
  const app = express();
  app.disable("x-powered-by");
  app.use(express.json({ limit: "32kb" }));

  app.get("/health", (_req, res) => {
    res.json({ ok: true });
  });

  app.post("/v1/auth/register", async (req, res, next) => {
    try {
      const { username, password, publicKey } = req.body ?? {};
      validateCredentials(username, password);
      const key = decodePublicKey(publicKey);
      const passwordHash = await hashPassword(password);
      try {
        const result = await pool.query(
          `INSERT INTO users (id, username, password_hash, public_key)
           VALUES (gen_random_uuid(), $1, $2, $3)
           RETURNING id, username`,
          [username, passwordHash, key]
        );
        res.status(201).json(tokenResponse(result.rows[0], env));
      } catch (error) {
        if (error.code === "23505") throw new HttpError(409, "username is taken");
        throw error;
      }
    } catch (error) {
      next(error);
    }
  });

  app.post("/v1/auth/login", async (req, res, next) => {
    try {
      const { username, password } = req.body ?? {};
      validateCredentials(username, password);
      const result = await pool.query(
        "SELECT id, username, password_hash FROM users WHERE username = $1",
        [username]
      );
      const user = result.rows[0];
      if (!user || !(await verifyPassword(password, user.password_hash))) {
        throw new HttpError(401, "invalid username or password");
      }
      res.json(tokenResponse(user, env));
    } catch (error) {
      next(error);
    }
  });

  app.put("/v1/users/me/public-key", requireUser(env), async (req, res, next) => {
    try {
      const key = decodePublicKey(req.body?.publicKey);
      await pool.query("UPDATE users SET public_key = $1 WHERE id = $2", [key, req.userId]);
      res.json({ status: "ok" });
    } catch (error) {
      next(error);
    }
  });

  app.get("/v1/users/:id/public-key", requireUser(env), async (req, res, next) => {
    try {
      const lookup = lookupUsersSql(req.params.id);
      const result = await pool.query(lookup.text, lookup.values);
      const row = result.rows[0];
      if (!row?.public_key) throw new HttpError(404, "public key not found");
      res.json({
        userId: row.id,
        username: row.username,
        publicKey: Buffer.from(row.public_key).toString("base64"),
      });
    } catch (error) {
      next(error);
    }
  });

  app.post("/v1/media/upload-url", requireUser(env), async (req, res, next) => {
    try {
      res.json(await createUploadTicket(s3, env, req.body?.byteLength));
    } catch (error) {
      next(error);
    }
  });

  app.post("/v1/media/download-url", requireUser(env), async (req, res, next) => {
    try {
      res.json(await createDownloadUrl(s3, env, req.body?.objectKey));
    } catch (error) {
      next(error);
    }
  });

  app.use((error, _req, res, _next) => {
    if (error instanceof HttpError) {
      res.status(error.status).json({ error: error.message });
      return;
    }
    if (error?.code === "22P02") {
      res.status(404).json({ error: "user not found" });
      return;
    }
    console.error(error);
    res.status(500).json({ error: "internal error" });
  });

  return app;
}

const userIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function lookupUsersSql(identifier) {
  if (userIdPattern.test(identifier)) {
    return {
      text: "SELECT id, username, public_key FROM users WHERE id = $1",
      values: [identifier],
    };
  }
  return {
    text: "SELECT id, username, public_key FROM users WHERE username = $1",
    values: [identifier],
  };
}

function tokenResponse(user, env) {
  const token = jwt.sign({ username: user.username }, env.JWT_SECRET, {
    subject: user.id,
    expiresIn: "30d",
  });
  return { userId: user.id, username: user.username, token };
}

function requireUser(env) {
  return (req, res, next) => {
    const header = req.get("authorization") ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : "";
    try {
      const payload = jwt.verify(token, env.JWT_SECRET);
      req.userId = payload.sub;
      next();
    } catch {
      next(new HttpError(401, "missing or invalid token"));
    }
  };
}

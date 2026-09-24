import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";

const scrypt = promisify(scryptCallback);

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function decodePublicKey(encoded) {
  if (typeof encoded !== "string") {
    throw new HttpError(400, "publicKey is required");
  }
  const key = Buffer.from(encoded, "base64");
  if (key.length !== 32) {
    throw new HttpError(400, "publicKey must be 32 bytes");
  }
  return key;
}

export async function hashPassword(password) {
  const salt = randomBytes(16);
  const hash = await scrypt(password, salt, 32);
  return `scrypt$${salt.toString("hex")}$${hash.toString("hex")}`;
}

export async function verifyPassword(password, stored) {
  const [scheme, saltHex, hashHex] = String(stored).split("$");
  if (scheme !== "scrypt" || !saltHex || !hashHex) return false;
  const actual = Buffer.from(hashHex, "hex");
  const candidate = await scrypt(password, Buffer.from(saltHex, "hex"), actual.length);
  if (candidate.length !== actual.length) return false;
  return timingSafeEqual(candidate, actual);
}

const usernamePattern = /^[a-zA-Z0-9_]{3,32}$/;

export function validateCredentials(username, password) {
  if (!usernamePattern.test(username ?? "")) {
    throw new HttpError(400, "username must be 3-32 letters, numbers, or underscores");
  }
  if (typeof password !== "string" || password.length < 8 || password.length > 200) {
    throw new HttpError(400, "password must be 8-200 characters");
  }
}

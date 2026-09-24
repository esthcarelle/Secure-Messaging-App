import assert from "node:assert/strict";
import test from "node:test";
import { lookupUsersSql } from "../src/app.js";
import { decodePublicKey, hashPassword, validateCredentials, verifyPassword } from "../src/auth.js";
import { validateObjectKey } from "../src/media.js";

test("password hash verifies and rejects a wrong password", async () => {
  const stored = await hashPassword("correct-horse");
  assert.equal(await verifyPassword("correct-horse", stored), true);
  assert.equal(await verifyPassword("wrong-horse", stored), false);
});

test("public keys must be 32 bytes", () => {
  assert.equal(decodePublicKey(Buffer.alloc(32, 7).toString("base64")).length, 32);
  assert.throws(() => decodePublicKey(Buffer.alloc(16).toString("base64")));
  assert.throws(() => validateCredentials("ab", "longenough"));
  assert.throws(() => validateCredentials("alice", "short"));
});

test("public key lookup uses username unless the value is a user id", () => {
  assert.match(lookupUsersSql("esther").text, /username = \$1/);
  assert.match(
    lookupUsersSql("9d2ae1c0-6e6f-4de0-99b2-829674978bea").text,
    /WHERE id = \$1/
  );
});

test("object keys are limited to unguessable ciphertext paths", () => {
  validateObjectKey("ciphertext/6f1b1c3e-9a0d-4e1a-9c2b-6a0d9e1c3b11");
  assert.throws(() => validateObjectKey("ciphertext/../secret"));
  assert.throws(() => validateObjectKey("users/alice/photo.jpg"));
});

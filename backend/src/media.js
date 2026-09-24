import { randomUUID } from "node:crypto";
import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { HttpError } from "./auth.js";

const objectKeyPattern =
  /^ciphertext\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export const maxBlobBytes = 25 * 1024 * 1024;

export function validateObjectKey(objectKey) {
  if (typeof objectKey !== "string" || !objectKeyPattern.test(objectKey)) {
    throw new HttpError(400, "objectKey is not a ciphertext object");
  }
  return objectKey;
}

export function createS3Client(env = process.env) {
  return new S3Client({
    region: env.S3_REGION || "auto",
    endpoint: env.S3_ENDPOINT || undefined,
    forcePathStyle: true,
    credentials: {
      accessKeyId: env.S3_ACCESS_KEY || "",
      secretAccessKey: env.S3_SECRET_KEY || "",
    },
  });
}

export async function createUploadTicket(s3, env, byteLength) {
  const length = Number(byteLength);
  if (!Number.isInteger(length) || length < 1 || length > maxBlobBytes) {
    throw new HttpError(400, "byteLength must be between 1 and 25MB");
  }
  const bucket = env.S3_BUCKET;
  const objectKey = `ciphertext/${randomUUID()}`;
  const command = new PutObjectCommand({
    Bucket: bucket,
    Key: objectKey,
    ContentType: "application/octet-stream",
  });
  const uploadUrl = await getSignedUrl(s3, command, { expiresIn: 600 });
  return {
    objectKey,
    uploadUrl,
    s3FileUrl: `s3://${bucket}/${objectKey}`,
  };
}

export async function createDownloadUrl(s3, env, objectKey) {
  const key = validateObjectKey(objectKey);
  const command = new GetObjectCommand({
    Bucket: env.S3_BUCKET,
    Key: key,
  });
  const downloadUrl = await getSignedUrl(s3, command, { expiresIn: 600 });
  return { downloadUrl };
}

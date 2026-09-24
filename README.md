# Secure Messaging

End-to-end encrypted text and photo messaging. The iOS app encrypts every payload before it leaves the device. The backend stores account records, Curve25519 public keys, and opaque media blobs. It never receives plaintext messages or file keys.

The app targets iOS 15 so the client can use structured concurrency and `Color(uiColor:)`. The UI still follows the requested MVVM split, semantic colors, asset-catalog bubbles, and an in-app appearance override.

## Layout

| Piece | Where |
| --- | --- |
| Protobuf schema | `proto/messaging.proto` |
| Swift codec, Libsodium + CryptoKit pipeline, SQLCipher, attachment upload | `Sources/SecureMessagingKit` |
| SwiftUI chat, theme, key management, MQTT | `ios/SecureMessaging` |
| Public-key directory and pre-signed media URLs | `backend` |
| Local Postgres, MinIO, and EMQX | `docker-compose.yml` |

## Message path

Outgoing text:

1. Pack the text into a `TextPayload`.
2. SHA-256 that plaintext with CryptoKit and store the digest in `hash_signature`.
3. Encrypt it with libsodium `crypto_box_easy` (X25519 + XSalsa20-Poly1305) under the recipient's Curve25519 public key and a fresh 24-byte nonce.
4. Publish the `MessageEnvelope` to `users/{recipientId}/messages` at MQTT QoS 1.
5. Save the decrypted copy in SQLCipher. The 256-bit database key lives in the iOS Keychain.

Outgoing photo:

1. Compress on device, then encrypt the bytes with `crypto_secretbox_easy` and a random 256-bit key.
2. Upload `nonce || ciphertext` to S3 (or MinIO / R2) through a pre-signed PUT. The server does not see the file.
3. Wrap the symmetric key with `crypto_box_easy` and put the wrapped key, its nonce, and `s3://bucket/ciphertext/{id}` into an `AttachmentPayload`.
4. Encrypt that payload with the same envelope steps as text, including a thumbnail sealed under the file key.

Incoming messages check the libsodium MAC during `crypto_box_open_easy`, then compare the SHA-256 of the decrypted payload with `hash_signature` before the message is shown or stored. A failed check is discarded.

The blob stored in object storage is not a long-lived URL. `s3_file_url` carries an unguessable object key. The recipient asks `POST /v1/media/download-url` for a short-lived GET. Presigned URLs expire, so they are not embedded in message history.

## Backend

`POST /v1/auth/register` and `POST /v1/auth/login` issue a JWT. The register call stores the 32-byte public key. `GET /v1/users/{id}/public-key` is the lookup used before sealing a message. Private keys are not accepted and are not stored.

`POST /v1/media/upload-url` returns a pre-signed PUT for `ciphertext/{uuid}` with content type `application/octet-stream`. Request bodies are capped at 32 KB because file bytes must not pass through the API.

MQTT topics are `users/{userId}/messages` and `users/{userId}/ack`. The client sets `cleanSession` to false and publishes at QoS 1 so an offline recipient can receive queued messages when EMQX has a persistent session.

## What this design does not claim

`crypto_box` uses long-term identity keys. A later compromise of a secret key can decrypt messages sealed to that key. This is not a Signal-style Double Ratchet, and it does not provide post-compromise forward secrecy.

The broker and the directory can see account ids, timestamps, ciphertext sizes, and object-key requests. They cannot see message text, filenames inside the encrypted payload, media bytes, or symmetric keys.

Identity is one key pair per install, kept in the Keychain. Logging in on a second device does not recover history, because the server never had the secret key.

## Run the tests

```bash
swift test
cd backend && npm install && npm test
```

`swift test` covers protobuf round-trips, text and attachment encryption, tampered ciphertext, tampered hashes, SQLCipher open with the wrong key, and a full upload/download through a fake object store.

## Run the local stack

```bash
docker compose up -d
cp backend/.env.example backend/.env
cd backend && npm install && npm start
```

EMQX listens on `127.0.0.1:1883`. The dashboard is port 18083 (`admin` / `public`). Allow anonymous connections there for local development, then turn that off and authenticate clients with the directory JWT before any shared network. MinIO is on port 9000; the init container creates the `ciphertext` bucket.

## Open the iOS app

```bash
cd ios && xcodegen generate
open SecureMessaging.xcodeproj
```

The simulator reaches the host at `127.0.0.1`, which is what `AppConfig` uses. Create two accounts from two simulator instances, copy a user id into the recipient field, and compare the safety number in Settings before trusting a key. Appearance is System Default, Always Light, or Always Dark, applied with `preferredColorScheme`. Bubble colors come from the asset catalog so they follow light and dark mode.

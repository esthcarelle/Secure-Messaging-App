# Secure Messaging

End-to-end encrypted text and photo messaging for iOS. The phone encrypts every payload before it leaves the device. The backend stores accounts, Curve25519 public keys, and opaque media blobs. It never receives plaintext messages or file keys.

## Required dependencies and setup

Install these on the Mac that will run the stack and the simulator:

| Tool | Used for |
| --- | --- |
| Docker Desktop | Postgres, MinIO, and EMQX |
| Node.js 20 or newer | The directory API (`node --env-file` needs 20+) |
| Xcode 15 or newer | The iOS app, deployment target iOS 15 |
| XcodeGen (`brew install xcodegen`) | Generates `ios/SecureMessaging.xcodeproj` |
| Swift 6 toolchain | Comes with Xcode; also runs `swift test` |

Swift Package Manager fetches the app libraries. You do not install them by hand.

| Package | Role |
| --- | --- |
| [swift-sodium](https://github.com/jedisct1/swift-sodium) 0.11+ | libsodium `crypto_box` and `crypto_secretbox` |
| [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) 4.10+ | Encrypted local message database |
| [CocoaMQTT](https://github.com/emqx/CocoaMQTT) 2.1+ | MQTT client |

The API dependencies are in `backend/package.json`: Express, `pg`, `jsonwebtoken`, and the AWS S3 client used against MinIO.

`ios/SecureMessaging/Config/AppConfig.swift` points the app at the host machine:

- API: `http://127.0.0.1:8080`
- MQTT: `127.0.0.1:1883`, TLS off

That address works from the iOS Simulator. A physical iPhone would need the Mac's LAN address instead.

## Build and run locally

From the repository root:

```bash
docker compose up -d
cp backend/.env.example backend/.env
cd backend
npm install
npm start
```

On startup the API applies `backend/sql/schema.sql` and listens on port 8080. Check it with:

```bash
curl http://127.0.0.1:8080/health
```

A healthy process returns `{"ok":true}`.

Postgres is published on host port **5433** (`postgres://messaging:messaging@localhost:5433/messaging`) so it does not collide with another Postgres already bound to 5432. If port 8080 is already taken, stop the old process before `npm start`.

Local services:

| Service | Address | Notes |
| --- | --- | --- |
| API | http://127.0.0.1:8080 | JWT directory and pre-signed media URLs |
| Postgres | localhost:5433 | User, password, and database are all `messaging` |
| MinIO | http://127.0.0.1:9000 | Console on port 9001, user `minio`, password `minio12345` |
| EMQX | 127.0.0.1:1883 | Dashboard on port 18083, `admin` / `public` |

The MinIO init container creates the `ciphertext` bucket. EMQX on this compose file accepts connections so the simulators can subscribe. The app still sends the user id and JWT as the MQTT username and password. The local broker does not verify that token.

Generate the Xcode project and open it:

```bash
cd ios
xcodegen generate
open SecureMessaging.xcodeproj
```

In Xcode, choose an iPhone simulator and press Run. To try two people, run the app on a second simulator as well (change the run destination and press Run again; the first simulator keeps the installed app). Create a different account on each one. Username must be at least 3 characters and the password at least 8.

On each phone:

1. Allow notifications when iOS asks.
2. Type the other account's username and tap **Open**. The status line should say the chat is ready.
3. Send a message. It is published to `users/{their-user-id}/messages`.
4. The other simulator shows the message and a banner while that app is still running.

Compare the safety number in Settings on both phones before tapping verify.

Run the automated tests from the repository root:

```bash
swift test
cd backend && npm test
```

`swift test` covers protobuf round-trips, text and attachment encryption, tampered ciphertext, tampered hashes, SQLCipher open with the wrong key, and a full upload/download through a fake object store.

## Architecture

```text
iOS app                         Mac (local)
┌─────────────────────┐         ┌──────────────────────────┐
│ SwiftUI + MVVM      │         │ Express API :8080        │
│ SecureMessagingKit  │─ REST ─▶│ Postgres (accounts, keys)│
│ SQLCipher + Keychain│         │ MinIO (opaque blobs)     │
│ CocoaMQTT           │─ MQTT ─▶│ EMQX :1883               │
└─────────────────────┘         └──────────────────────────┘
```

### iOS

The app is SwiftUI with an MVVM split.

- `KeyManagementViewModel` registers or logs in, keeps the identity in the Keychain, opens SQLCipher, and connects MQTT.
- `ChatViewModel` resolves a username to a user id, seals or opens envelopes, and reloads the open conversation.
- `AttachmentViewModel` picks a photo, compresses it, and hands the bytes to `AttachmentManager`.
- `MQTTManager` subscribes to `users/{userId}/messages` and `users/{userId}/ack` at QoS 1 with `cleanSession = false`. The MQTT client id is the user id.
- `MessageNotifier` posts a local notification after a message has been decrypted on the device.

`SecureMessagingKit` is the shared library: protobuf codec, `CryptoService`, `DatabaseService`, Keychain, and attachment upload/download. The UI never talks to Postgres or MinIO directly.

Decrypted history stays in SQLCipher. The 256-bit database key is created on the device and stored in the Keychain (`com.securemessaging.keystore`). The server has no message table.

### Backend

The API is a small Node.js Express service.

| Route | Purpose |
| --- | --- |
| `GET /health` | Liveness |
| `POST /v1/auth/register` | Create the account, store the 32-byte public key, return a JWT |
| `POST /v1/auth/login` | Check the scrypt password hash and return a JWT |
| `PUT /v1/users/me/public-key` | Replace this account's public key |
| `GET /v1/users/:id/public-key` | Look up a public key by username or user id |
| `POST /v1/media/upload-url` | Pre-signed PUT for `ciphertext/{uuid}` |
| `POST /v1/media/download-url` | Short-lived pre-signed GET for an object key the client already has |

Passwords are hashed with scrypt. Private keys are rejected and are not stored. JSON bodies are capped at 32 KB so file bytes cannot be posted to the API.

There is no chat log on the server. Live delivery is MQTT. The sender publishes a `MessageEnvelope` to the recipient's topic. The recipient publishes the message id on `users/{senderId}/ack` after a successful open. A "sent" state means EMQX returned PUBACK. "Delivered" means the other phone sent that ack.

## Encryption

Text and the attachment descriptor use libsodium `crypto_box_easy`: X25519 key agreement plus XSalsa20-Poly1305. Each seal uses a fresh 24-byte nonce and the recipient's long-term Curve25519 public key. The sender's secret key stays in the Keychain.

Before encryption, CryptoKit SHA-256 hashes the plaintext payload. That digest is stored in the envelope field `hash_signature`. On open, `crypto_box_open_easy` checks the libsodium MAC. The client then hashes the recovered plaintext again and compares it with `hash_signature`. A mismatch is discarded, so a payload swapped after a valid box still fails.

The wire format is protobuf (`proto/messaging.proto`), encoded by a small handwritten codec in `Sources/SecureMessagingKit/Protobuf.swift`. The envelope carries `message_id`, `sender_id`, `recipient_id`, `timestamp`, and `payload_type` in the clear, plus `payload_bytes`, `nonce`, and `hash_signature`.

Photos:

1. The image is compressed on the device.
2. The file is encrypted with `crypto_secretbox_easy` under a random 256-bit key.
3. The upload is `24-byte nonce || ciphertext`. MinIO stores that blob and cannot read the image.
4. The file key is wrapped with `crypto_box_easy` for the recipient and placed in `AttachmentPayload`, along with `s3://bucket/ciphertext/{id}`.
5. The thumbnail uses the same secretbox layout under the file key.
6. `AttachmentPayload` is sealed inside a `MessageEnvelope` with the same box and SHA-256 steps as text.

`s3_file_url` is an object key, not a long-lived link. The recipient exchanges it for a short-lived pre-signed GET. Those URLs are not written into message history.

Identity is one key pair per install. Logging in on another device creates a new pair. The server never had the old secret, so it cannot restore the old history.

This uses long-term identity keys. A later compromise of a secret key can decrypt messages that were sealed to that key. There is no Signal-style Double Ratchet and no post-compromise forward secrecy.

The broker and the directory can see account ids, timestamps, ciphertext sizes, and object-key requests. They cannot see message text, filenames inside the encrypted payload, media bytes, or symmetric keys.

## Implemented features

- Register and log in with a username and password.
- Curve25519 identity keys generated on device and stored in the Keychain.
- Public-key directory lookup by username or user id.
- End-to-end encrypted text, published over MQTT QoS 1.
- End-to-end encrypted photos, including an encrypted thumbnail, through pre-signed MinIO URLs.
- Delivery states: pending, sent (broker PUBACK), delivered (recipient ack), and failed.
- Local history in SQLCipher, reloaded when a conversation is opened.
- Incoming messages open that sender's chat automatically.
- The app refuses to publish a message to the account that is currently signed in.
- Safety number for the open contact, with an explicit verify action in Settings.
- Appearance override: System Default, Always Light, or Always Dark. Bubble colors come from the asset catalog.
- Local notification with the sender's username and a short decrypted preview, including while the app is in the foreground.

## Design choices

- The SHA-256 check sits beside the libsodium MAC, so authentication of the box and detection of a swapped plaintext are separate steps.
- Media never passes through the API. The phone uploads ciphertext with a pre-signed URL, and the API only mints that URL.
- The chat log lives only in SQLCipher. The database key is random, 256 bits, and kept in the Keychain.
- The recipient field accepts a username. The client resolves it to a user id and publishes to that id's MQTT topic.
- An incoming packet both updates the open conversation and raises a local notification after decryption, so the banner shows content the server never saw.
- The protobuf codec is handwritten against `messaging.proto`, which keeps the envelope free of a generated SwiftProtobuf dependency.
- Light and dark bubbles are asset-catalog colors, and the in-app appearance setting applies `preferredColorScheme` without fighting the system semantic colors.

## Known limitations

- Long-term `crypto_box` keys do not give forward secrecy after a secret key is compromised.
- Sender id, recipient id, timestamp, and payload type are visible in the envelope. The broker also sees topic names and payload sizes.
- One install, one identity. A second install of the same username does not recover the previous secret key or its SQLCipher history.
- `AppConfig` uses `127.0.0.1`. The iOS Simulator can reach the Mac. A physical iPhone cannot, until those URLs are changed to a reachable host.
- Local HTTP and MQTT are not using TLS.
- The local EMQX broker accepts the MQTT connection without checking the JWT.
- Notifications are local. They fire when this app process receives and decrypts the MQTT packet. A fully closed app does not get an Apple push notification, because MQTT is not a push service and this project does not talk to APNs.
- iOS suspends a background app and drops the socket. EMQX can queue for a persistent session, but a suspended app will not show a banner until it is running again and reconnects.
- "Sent" is the broker's PUBACK. The other phone still has to be connected, subscribed to its own user-id topic, and able to decrypt.

## Screenshots

Place images in `docs/screenshots/` using these names.

![Login and registration](docs/screenshots/login.png)

![Open chat and an encrypted text thread](docs/screenshots/chat.png)

![Photo attachment](docs/screenshots/attachment.png)

![Settings: appearance and safety number](docs/screenshots/settings.png)

![Message notification](docs/screenshots/notification.png)

## Layout

| Piece | Where |
| --- | --- |
| Protobuf schema | `proto/messaging.proto` |
| Swift codec, libsodium, CryptoKit, SQLCipher, attachments | `Sources/SecureMessagingKit` |
| SwiftUI chat, theme, MQTT, notifications | `ios/SecureMessaging` |
| Public-key directory and pre-signed media URLs | `backend` |
| Local Postgres, MinIO, and EMQX | `docker-compose.yml` |

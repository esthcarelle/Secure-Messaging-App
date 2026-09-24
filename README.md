# Secure Messaging

A private chat app for iPhone. Messages and photos are locked on the phone before they are sent. The server keeps accounts and public keys. It cannot read the chats.

## What you need

Install these on your Mac:


| Tool                | Why                                                             |
| ------------------- | --------------------------------------------------------------- |
| Docker Desktop      | Runs the database, file storage, and message broker             |
| Node.js 20 or newer | Runs the small API                                              |
| Xcode 15 or newer   | Builds the iPhone app                                           |
| XcodeGen            | Creates the Xcode project. Install with `brew install xcodegen` |


Xcode also includes Swift. The app downloads its own libraries when you build:

- **libsodium** (swift-sodium) locks and unlocks messages and photos
- **SQLCipher** stores chat history in an encrypted database on the phone
- **CocoaMQTT** delivers messages between phones

The API uses Express, Postgres, and a file store (MinIO, which works like S3). Those install with `npm install`.

The app talks to your Mac at `127.0.0.1`. Use the **iOS Simulator** in Xcode so that address works.

## Run it on your Mac

Open Terminal in this folder and start the services:

```bash
docker compose up -d
cp backend/.env.example backend/.env
cd backend
npm install
npm start
```

The API starts on port 8080 and creates the database tables for you. Check it:

```bash
curl http://127.0.0.1:8080/health
```

You should see `{"ok":true}`.


| Service               | Address                                        | Login                                                                          |
| --------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------ |
| API                   | [http://127.0.0.1:8080](http://127.0.0.1:8080) | —                                                                              |
| Database              | localhost:5433                                 | user `messaging`, password `messaging`                                         |
| File storage (MinIO)  | [http://127.0.0.1:9000](http://127.0.0.1:9000) | user `minio`, password `minio12345` (console on port 9001)                     |
| Message broker (EMQX) | 127.0.0.1:1883                                 | dashboard [http://127.0.0.1:18083](http://127.0.0.1:18083), `admin` / `public` |


Then open the app:

```bash
cd ios
xcodegen generate
open SecureMessaging.xcodeproj
```

In Xcode, pick an iPhone simulator and press Run.

To chat between two people, run the app on a second simulator too. Change the simulator in Xcode and press Run again. The first simulator keeps the app.

1. Create a different account on each simulator. Username at least 3 characters, password at least 8.
2. Allow notifications when the phone asks.
3. Type the other person’s username and tap **Open**.
4. Send a message. It shows up on the other simulator, with a notification banner.

Open Settings on both phones to compare the safety number, then mark the contact as verified.

To run the tests:

```bash
swift test
cd backend && npm test
```



## How it is built

The phone does the private work. The Mac only helps the two phones find each other and pass locked data.

```text
iPhone                         Your Mac
┌─────────────────────┐        ┌─────────────────────────┐
│ Chat screen         │        │ API (accounts and keys) │
│ Lock and unlock     │─ REST ▶│ Database                │
│ Saved chats         │        │ File storage            │
│ Live messages       │─ MQTT ▶│ Message broker          │
└─────────────────────┘        └─────────────────────────┘
```



### iPhone app

The screens are SwiftUI. Each screen has a view model that holds the logic.

- Sign-up and login create a key pair and save the secret key in the iPhone Keychain.
- The chat screen looks up the other person by username, locks the message for them, and sends it.
- Photos are shrunk on the phone, locked, then uploaded.
- Old messages are saved in an encrypted database on the phone (SQLCipher). The key for that database is also in the Keychain.
- When a new message arrives, the app unlocks it, shows the chat, and posts a notification.



### Backend

A small Node.js API. It does not store messages.


| Address                        | What it does                                                 |
| ------------------------------ | ------------------------------------------------------------ |
| `GET /health`                  | Says the API is up                                           |
| `POST /v1/auth/register`       | Creates an account and saves the public key                  |
| `POST /v1/auth/login`          | Checks the password and returns a login token                |
| `GET /v1/users/:id/public-key` | Finds someone by username or id and returns their public key |
| `POST /v1/media/upload-url`    | Gives the phone a short-lived link to upload a locked photo  |
| `POST /v1/media/download-url`  | Gives the phone a short-lived link to download that photo    |


Passwords are stored as a scrypt hash. The server only keeps the public key. The secret key stays on the phone.

Live chat goes through MQTT. Each person has a topic, `users/{their-id}/messages`. After the other phone unlocks a message, it sends a small receipt so the sender can show **Delivered**.

## How encryption works

Each account has a key pair from **libsodium**. The public key is safe to share. The secret key stays in the Keychain.

**Text.** The app locks the text with libsodium `crypto_box`. That uses the other person’s public key, so only their secret key can open it. A new random nonce is used every time.

**Hash check.** Before locking, the app hashes the message with **SHA-256** (CryptoKit). The hash is sent in the field `hash_signature`. When the other phone opens the message, libsodium checks the lock. The phone then hashes the opened text again and compares it with `hash_signature`. If the hash does not match, the message is thrown away.

**Photos.** The picture is locked with libsodium `crypto_secretbox` and a one-time file key. The locked file is uploaded to MinIO. The file key is then locked with `crypto_box` for the recipient and sent inside the chat message, along with a small locked thumbnail. The server stores the file and cannot open it.

**On the wire.** Messages use a small protobuf layout (`proto/messaging.proto`). The chat text itself is inside the locked bytes.

**On the phone.** Opened chats sit in SQLCipher. A 256-bit key in the Keychain opens that database.

## What the app can do

- Create an account and log in
- Send locked text messages
- Send locked photos
- Show sent and delivered
- Keep chat history on the phone
- Open the right chat when a message arrives
- Show a notification with the sender’s name and a short preview
- Show a safety number so two people can confirm they have the right keys
- Switch between system, light, and dark appearance



## Extra touches

- Two checks on every message: the libsodium lock, then the SHA-256 hash
- Photos go straight to file storage. The API only hands out a temporary upload link
- Chat history never goes to the server. It stays in the encrypted database on the phone
- You can type a username. The app finds the right person and sends the message to them
- A new message opens that chat and shows a notification after the phone has unlocked it
- Light and dark chat bubbles follow the appearance setting



## Demo

[Watch the demo](docs/demo.mov)

## Where things live


| Part                               | Folder                       |
| ---------------------------------- | ---------------------------- |
| Message format                     | `proto/messaging.proto`      |
| Locking, database, and photos      | `Sources/SecureMessagingKit` |
| iPhone screens                     | `ios/SecureMessaging`        |
| API                                | `backend`                    |
| Database, file storage, and broker | `docker-compose.yml`         |



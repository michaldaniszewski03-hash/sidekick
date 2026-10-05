# Sidekick architecture

Sidekick connects a person's own devices (send files both ways, shared
clipboard, phone as a touchpad, Screen Mirroring, Ping). The short version:
**one Flutter app for all four platforms, no backend, no accounts, no
payments.** Every device runs its own small encrypted server and talks
directly to the devices it's paired with. The only server-side code is the
website's wishlist form.

## The apps

One codebase in `app/`, written in **Dart with Flutter**, built for four
platforms. Each platform adds a thin native layer for what Flutter can't do,
called through method channels (`sidekick/ios`, `sidekick/macos`,
`sidekick/android`, `sidekick/mirror`, …).

| Platform | Built with | Native code (what it's for) | Shipped as |
|---|---|---|---|
| **Windows** | Flutter (Win32 runner) | C++ runner (`windows/runner`, `/W4 /WX`); Win32 calls through Dart FFI (input, clipboard, sounds); PowerShell WinRT for Wi-Fi Direct | `SidekickSetup-X.Y.Z.exe` (installer) |
| **macOS** | Flutter | Swift (`macos/Runner`): CoreBluetooth (`SidekickBLE.swift`), Apple peer-to-peer Wi-Fi (`SidekickP2P.swift`), menu bar, sounds, clipboard | `.dmg` and `.pkg` |
| **Android** | Flutter | Kotlin (`android/app/src/main/kotlin`): background engine and service, notifications, MediaProjection screen capture, accessibility input, hotspot, gallery | `.apk` |
| **iPhone** | Flutter | Swift (`ios/Runner`): CoreBluetooth, peer-to-peer Wi-Fi, notifications, background keep-alive, Photos; two app extensions: **SidekickLive** (Live Activities, WidgetKit) and **SidekickMirror** (ReplayKit screen broadcast) | `.ipa` (AltStore / SideStore / Sideloadly) and TestFlight |

Key Dart packages (`app/pubspec.yaml`): `shelf` / `shelf_router` /
`shelf_web_socket` (the built-in server), `pointycastle` + `basic_utils` +
`crypto` (certificates, SPAKE2, AES-GCM), `bluetooth_low_energy` (Bluetooth
on Android and Windows), `flutter_secure_storage` (secrets),
`shared_preferences` (settings), `mobile_scanner` + `qr_flutter` (QR pairing),
`window_manager` + `tray_manager` (desktop window and tray), `material_ui`
(the UI library).

The code is split into:

- `lib/core/`: platform-independent logic, unit-tested (server, client,
  crypto, discovery, Bluetooth protocol, Screen Mirroring packets).
- `lib/platform/`: per-OS glue over the native channels.
- `lib/ui/`: screens.
- `lib/app_state.dart`: the app's state (devices, transfers, settings).

CI (`.github/workflows/build.yml`, GitHub Actions) tests and builds all four
platforms on every push, and publishes a GitHub Release when run with a
`release_tag`.

## Is there a backend?

**No.** There is no Sidekick server, no cloud, no database and no
analytics. The app never contacts the developer, and it doesn't go online
to check for updates.

Instead, **every device is its own server**, and devices talk peer to peer:

1. **Finding each other:** UDP multicast/broadcast announcements on the local
   network (`core/discovery.dart`), Bluetooth LE advertising (off by
   default), and, between iPhones and Macs, Apple's peer-to-peer Wi-Fi
   (Bonjour `_sidekick-p2p._tcp`).
2. **Talking:** each device runs an **HTTPS server on port 53318**
   (`core/server.dart`), and peers call it with `PeerClient`
   (`core/client.dart`).
3. **When there's no shared Wi-Fi:** one device opens a small private Wi-Fi
   network (Android hotspot or Windows Wi-Fi Direct) and the other joins it,
   or the two use Apple's peer-to-peer link. Bluetooth is the fallback for
   small messages.

## The API (device to device)

A versioned HTTP API under `/v1`, served by every device to the devices
paired with it:

| Area | Endpoints |
|---|---|
| Who's there | `GET /v1/info` |
| Pairing | `POST /v1/pair/request`, `/v1/pair/start`, `/v1/pair/confirm`, `/v1/unpair` |
| Files | `GET /v1/fs/roots`, `/v1/fs/list`, `/v1/fs/download`; `POST /v1/fs/upload`, `/v1/fs/upload/part` |
| Sending files (ask first) | `POST /v1/transfer/offer`, `/v1/transfer/cancel` |
| Clipboard, Ping | `POST /v1/clipboard`, `POST /v1/ping` |
| Remote control | `GET /v1/input/status`; `GET /v1/input` (WebSocket) |
| Screen Mirroring | `GET /v1/mirror/status`; `GET /v1/mirror` (WebSocket, binary tile packets) |
| Direct Wi-Fi link | `POST /v1/link/hotspot`, `/v1/link/join`, `/v1/link/release` |

The same handler also serves these requests over Bluetooth
(`core/ble_protocol.dart`: framed, chunked, sealed messages).

**Security:**

- **Pairing:** a 6-digit code or a QR code, using SPAKE2, so the code itself
  never travels.
- **After pairing:**
  - over Wi-Fi, TLS pinned to each device's own certificate, plus a bearer
    token;
  - over Bluetooth, AES-GCM with keys agreed when pairing.
- **Permissions:** what a paired device may do (browse files, remote
  control, Screen Mirroring) is switched on or off in Settings, and
  receiving files and Screen Mirroring ask the user first.

## Where user data is stored

Everything stays **on the user's own devices**. Nothing is uploaded anywhere.

| Data | Where |
|---|---|
| Settings (device name, theme, sound, receive folder, permissions) | `shared_preferences` (the platform's normal app preferences) |
| Paired devices' tokens and keys, this device's private key | System secure storage: **Keychain** (iPhone), **Android Keystore** (encrypted), **DPAPI** (Windows); on the **Mac** a `secrets.json` file in Application Support readable only by the user (0600), not the Keychain, which nags unsigned apps |
| Received files | Windows/Mac: `Downloads/Sidekick` (or a folder the user picks). Android: `Download/Sidekick` with "All files access", otherwise the app's own folder. iPhone: the app's Documents folder (Files app → On My iPhone → Sidekick) |
| Received photos and videos (phones) | Moved into **Photos** (iPhone, add-only access) or the **gallery** (Android: Pictures/Sidekick, Movies/Sidekick) |

### The one server-side piece: the website's wishlist

- **The site:** `index.html`, `privacy.html` and the other pages are static
  files at **getsidekick.app**, on OVHcloud web hosting. `wishlist.php` is
  plain PHP with no database. Static files only, apart from that one script.
- **What it stores:** the wishlist form posts to `wishlist.php`, which keeps
  sign-ups in `sidekick-wishlist/list.csv` on the hosting. That folder sits
  outside the public web folder, and holds the email, the devices picked and
  the time.
- **The emails:** it sends "Got your email!" with PHP `mail()` from
  `info@getsidekick.app`, with a link to remove the address, and a note to
  the owner for each sign-up.
- **Abuse protection:** a hidden trap field, a 2-second minimum, and 5 tries
  an hour per IP; only a salted hash of the IP is kept, for an hour.
- This is the only personal data held off the user's devices. Both privacy
  policies (`privacy.html`, `app/packaging/privacy.txt`) describe it.

## Sign-in

**There is none.** Sidekick has no accounts, no sign-up, no passwords, and
no third-party login (no Google, Apple or email sign-in).

Identity is per device, not per person:

- **Each device's identity:** on first start, each device creates its own
  certificate and key pair and a random device ID.
- **Trust:** comes from **pairing** two devices in person, with a 6-digit
  code or a QR code.
- **Withdrawing it:** unpairing removes it on both sides.

## Payments

**There are none.** Sidekick is free:

- no in-app purchases;
- no subscriptions;
- no ads;
- no payment code or payment provider anywhere in the project.

The apps are distributed directly (GitHub Releases, AltStore/SideStore,
TestFlight), not through the App Store, Google Play or the Microsoft Store.

## See also

- `CLAUDE.md`: the detailed developer notes (every subsystem, conventions,
  how to release, version history).
- `privacy.html` / `app/packaging/privacy.txt`: what's stored, what's shared,
  and every permission, for users.

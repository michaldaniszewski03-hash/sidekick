# Sidekick

Sidekick combines LocalSend and KDE Connect in one app. It links your phone and computer over your local network so you can:

- **Remote control, both ways:** use your phone as a touchpad and keyboard for your PC, or control your Android phone from your PC.
- **Browse files:** open the other device's storage and pull files across.
- **Share files:** send files of any size with drag and drop or the share sheet. No cloud involved.
- **Control media:** play, pause, seek, skip, and change the volume of whatever is playing on the other device.

Platforms: **Android, iOS, Windows, macOS** (Linux comes almost free with the same stack).

## Apps (v1.0): Windows, Android, macOS and iOS

The Flutter app lives in `app/`. One codebase builds all four apps.

### Install

Download both from the [**Releases** page](https://github.com/michaldaniszewski03-hash/sidekick/releases):

- **Windows 10/11:** run **`SidekickSetup-<version>.exe`**. It installs Sidekick with Start menu and desktop shortcuts, allows it through Windows Firewall on private networks, and adds an uninstaller. The installer isn't code-signed yet, so Windows may say "Windows protected your PC": click **More info → Run anyway**.
- **Android 8.0+:** open **`Sidekick-<version>.apk`** on your phone. If asked, allow your browser or Files app to install apps.
- **macOS 12+:** open **`Sidekick-<version>.dmg`** and drag Sidekick into Applications. The app isn't notarized yet, so the first time, right-click it → **Open** → **Open**. On macOS 15 and newer, try to open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
- **iPhone/iPad (iOS 15+):** the **`Sidekick-<version>.ipa`** is unsigned, because signing needs a paid Apple Developer account. Install it with [AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io), which sign it with your own Apple ID. With a free Apple ID the app has to be re-signed every 7 days; those tools can do that automatically.

Every push also builds both on GitHub Actions (**Build** workflow → run → **Artifacts**), for testing between releases.

### First launch

Sidekick opens with a short welcome: what it does, a name for this device, the permissions this platform needs (skipped on Windows), a theme, and how to pair your other device. It shows once; everything in it can be changed later in Settings.

### Set up the phone

1. Open Sidekick on the phone and on the PC, on the same Wi-Fi. They show up under **Nearby** within a few seconds. If they don't, use **Add by IP**.
2. Tap **Pair** on one device and type the 6-digit code the other one shows.
3. That's enough for the phone to control the PC. For the PC to control the phone, open **Settings** on the phone and grant:
   - **All files access:** the PC can browse the phone's storage, and received files go to `Download/Sidekick`.
   - **Notification access:** the PC sees what's playing on the phone and can seek. Play/pause/next and volume work without it.
   - **Remote control (Accessibility):** the PC can tap, scroll and type on the phone. A dot shows where the "mouse" is. On Android 13 and newer, sideloaded apps need one extra step first: **App info → ⋮ → Allow restricted settings**.

### Without Wi-Fi: Bluetooth

Sidekick prefers Wi-Fi. When two devices can't reach each other over Wi-Fi (no router, a different network, or Wi-Fi off), they find each other over Bluetooth instead:

- Pairing, browsing files, small files and media controls work straight over Bluetooth.
- **Direct Wi-Fi link (like AirDrop):** for files over 2 MB and for remote control, an Android phone and a Windows PC or Mac use Bluetooth only to hand over the name and password of a private hotspot. The phone opens it (no mobile data is shared), the computer joins it on its own, and the transfer runs at full Wi-Fi speed. After 3 quiet minutes the phone closes the hotspot and the computer goes back to its usual network. You can also start it yourself with **Use Wi-Fi** in the Bluetooth banner.
- Without a direct link (e.g. iPhone ↔ PC, or phone ↔ phone), Bluetooth runs at tens of KB/s: fine for texts, photos and documents; files over 50 MB and remote control need Wi-Fi.
- **Pairing over Bluetooth:** Devices → **Bluetooth** (or **Pair over Bluetooth** under Nearby) searches continuously and lists every Sidekick device it hears, with its signal, while it reads each one's name, or why that failed (with **Retry**). Tap **Pair** and type the 6-digit code, exactly like on Wi-Fi.
- **No Wi-Fi anywhere** (a field, a train): open Sidekick on both devices with Bluetooth on and keep it on screen. Each searches every 10 seconds and shows the other under **Nearby** (or as "Connected via Bluetooth" if paired). **Settings → Bluetooth → Details** shows what it sees and why if something fails.
- The phone asks for **Nearby devices** permission (Location on Android 12 and older) the first time it opens a hotspot. Some phones can't open one while connected to another Wi-Fi network.
- Both devices need Bluetooth on and Sidekick open. Android asks for Bluetooth permission on first start; iPhone and Mac ask the first time Sidekick uses Bluetooth.
- The device card says **Connected via Bluetooth** while it's in use, and switches back to Wi-Fi automatically when that becomes available.

How it works: every device offers a small Bluetooth service. Requests travel over it in chunks and go through exactly the same code as on Wi-Fi, so pairing, tokens and permissions behave the same way (see `app/lib/core/ble_protocol.dart` and `bluetooth.dart`).

### Set up a Mac

To let your phone control the Mac, open **Settings** in Sidekick and click **Grant** next to **Accessibility**. Then turn Sidekick on in the list that opens. After updating the app you may need to switch it off and on again there, because macOS ties the permission to the app's signature.

The Mac's media controls use the play/pause and skip media keys plus the system volume. macOS doesn't let apps read what's playing, so the Media tab shows controls without a title.

### iPhone and iPad

**Install (one-time setup, then updates are one tap):** Apple only allows App Store apps without a paid developer account, so Sidekick installs through **AltStore** (or **SideStore**), which signs it with your own Apple ID.

1. On your Mac, install **AltServer** from [altstore.io](https://altstore.io), plug in the iPhone, and choose **Install AltStore** from AltServer's menu-bar icon. (SideStore works without a computer after its own setup: [sidestore.io](https://sidestore.io).)
2. On the iPhone: **Settings → General → VPN & Device Management** → trust your Apple ID. On iOS 16+ also turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
3. In AltStore: **Sources → +**, paste
   `https://github.com/michaldaniszewski03-hash/sidekick/releases/latest/download/altstore.json`
   then open **Sidekick → Install**.
4. New releases appear under **My Apps → Updates**.

**Or TestFlight (needs a paid Apple Developer account, $99/year):** CI uploads every release to TestFlight once these are set up. On the iPhone you then just open **TestFlight → Sidekick → Install**, and new releases arrive as updates. No 7-day limit (each build lasts 90 days), and it works on iOS betas.

1. Enroll at [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll) with the Apple ID that's signed in on your iPhone (approval usually takes up to 2 days).
2. In [Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list), add an **App ID** with the explicit bundle ID `dev.sidekick.sidekick`. If that's taken, use your own (e.g. `com.yourname.sidekick`) and add it as the repository **variable** `IOS_BUNDLE_ID`.
3. In [App Store Connect](https://appstoreconnect.apple.com) → **Apps → + → New App**: iOS, any name that's free on the store (e.g. "Sidekick Remote"), that bundle ID, any SKU.
4. **Users and Access → Integrations → App Store Connect API → Team Keys → +** with **Admin** access (needed so CI can create the signing certificate). Note the **Key ID** and **Issuer ID**, and download the `.p8` file (you can only download it once).
5. Your **Team ID** is under [Membership details](https://developer.apple.com/account).
6. In this repository on GitHub: **Settings → Secrets and variables → Actions → New repository secret**, add `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (paste the whole `.p8` file, including the BEGIN/END lines).
7. Publish a release. About 15 minutes after the upload, the build shows up in App Store Connect → **TestFlight**. Answer the export-compliance question once per build, add yourself to an **Internal Testing** group, then install it from the TestFlight app.

With a free Apple ID, sideloaded apps must be refreshed every 7 days. AltStore does it by itself in the background while your Mac with AltServer is on the same Wi-Fi; SideStore does it on the phone. You can also still install the `.ipa` from the release with [Sideloadly](https://sideloadly.io).

On iOS, Sidekick **controls your computer and shares files both ways**:
- Send photos, videos or files to a paired device: **Devices → Send**, then choose **Photos & videos** or **Files**.
- Files sent to the iPhone land in the **Files** app under **On My iPhone → Sidekick**.
- A paired computer can browse that Sidekick folder from its **Files** tab, and upload into it.

iOS doesn't allow other devices to control an iPhone, so the Remote and Media tabs only work *from* the iPhone. iOS also blocks the multicast discovery the other apps use, so the iPhone scans the Wi-Fi network instead (every 30 seconds, or tap **Scan network**). Allow **Local Network** access when iOS asks.

### Release a new version

1. Bump `version:` in `app/pubspec.yaml`, for example `0.2.0+2`.
2. On GitHub, go to **Releases → Draft a new release**, create a tag (for example `v0.2.0`), and click **Publish release**.

Within about 6 minutes the **Build** workflow attaches `SidekickSetup-<version>.exe` and `Sidekick-<version>.apk` to that release. Pushing a `v*` tag from the command line (`git tag v0.2.0 && git push origin v0.2.0`) does the same and creates the release for you.

To attach builds to a release that's missing them, go to **Actions → Build → Run workflow** and enter the release's tag.

With a `v` tag the file names take the version from the tag; otherwise they use the version in `pubspec.yaml`.

**Android signing (do this once):** until you add a signing key, each APK is signed with a throwaway key. Android then refuses to install one version over another, so you'd have to uninstall first. To fix that, create a key once and keep it safe:

```sh
keytool -genkey -v -keystore sidekick-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias sidekick
base64 -w0 sidekick-release.jks   # copy the output
```

In GitHub, go to **Settings → Secrets and variables → Actions** and add:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the base64 output |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | `sidekick` |
| `ANDROID_KEY_PASSWORD` | the key password |

### Build it yourself

- **Windows:** install [Flutter](https://docs.flutter.dev/get-started/install/windows/desktop) and Visual Studio 2022 with **Desktop development with C++**, then run `cd app && flutter run -d windows`.
- **Android:** install Flutter and Android Studio, plug in your phone with USB debugging on, then run `cd app && flutter run`.

### What works

| Tab | What it does |
|---|---|
| **Devices** | Finds Sidekick devices on your Wi-Fi, pairs with a 6-digit code, **Add by IP** if discovery is blocked, drag files onto a device card to send them |
| **Files** | Browse the other device's folders and drives, download files, upload into the open folder (button or drag and drop), transfer progress |
| **Remote** | Touchpad (drag to move, tap/click, right-click or long-press, scroll or two-finger scroll), a **Hold** toggle for dragging, typing (live keyboard capture on PC, a type-as-you-go box on the phone), shortcuts: Alt+Tab, Win+D, Ctrl+C/V… for a PC; Back, Home, Recent apps, Notifications… for a phone |
| **Media** | Title, artist and app of whatever's playing, play/pause, previous/next, ±10 s, a seek bar, a volume slider, mute |
| **Settings** | Device name, the folder received files go to, switches for what paired devices may do, light/dark mode |

When a paired device is controlling this device, a banner says so, with a button that unpairs it and stops the session right away.

**Controlling an iPhone's audio from a computer:** iOS only lets apps change the system volume (and mute) and control **Apple Music**; it doesn't allow controlling other apps like YouTube or Spotify. iOS also pauses apps you're not using, so Sidekick has **Settings → iPhone → Keep running in the background** (on by default): a silent audio session, mixed with whatever you play, keeps it reachable while you're in Music or another app.

**Controlling the phone from the PC:** clicks become taps at the dot, the wheel becomes swipes, and Esc/Win map to Back/Home. Typing goes into whatever text field is focused on the phone.

### How it works

```
app/lib/
├── main.dart            Material 3 theme (Windows accent color / Android wallpaper colors)
├── app_state.dart       all app state: devices, pairing, transfers, settings
├── core/
│   ├── models.dart      JSON types shared by every platform
│   ├── discovery.dart   UDP multicast announcements (224.0.0.168:53318)
│   ├── server.dart      HTTPS + WebSocket server every device runs (port 53318)
│   ├── crypto.dart      certificates, SPAKE2 pairing, AES-GCM sealing
│   ├── client.dart      talks to another device's server
│   └── trust.dart       pairing codes, tokens, trusted devices
├── platform/
│   ├── input.dart       mouse/keyboard via Win32 SendInput (dart:ffi)
│   ├── media.dart       Windows media sessions + volume via a PowerShell helper
│   ├── android.dart     bridge to the Kotlin side on Android
│   ├── macos.dart       bridge to the Swift side on macOS
│   └── files.dart       folder listing, safe file names
└── ui/                  one file per tab

app/android/app/src/main/kotlin/dev/sidekick/sidekick/
├── MainActivity.kt                    permissions, multicast lock, method channel
├── SidekickAccessibilityService.kt    PC → phone taps, swipes, keys, typing
└── MediaBridge.kt                     phone media sessions and volume
app/macos/Runner/MainFlutterWindow.swift  Mac input (CGEvent), media keys, volume
app/windows/installer/sidekick.iss     Windows installer (Inno Setup)
app/tool/make_icons.py                 app icons for every platform from your logo
```

- **Pairing:** device A asks B to pair; B shows a 6-digit code; you type it on A. Both devices then hold a random token for each other. Pairing works both ways, so either device can control the other. After 5 wrong codes, or 2 minutes, the code stops working.
- **Every request except `/v1/info` and pairing needs a token.** Unpairing revokes the token straight away, including any live remote-control session.

### Encryption

Everything between paired devices is encrypted, on Wi-Fi and on Bluetooth (`app/lib/core/crypto.dart`):

- **Each device has its own certificate** (P-256, made on first start). All Wi-Fi traffic is HTTPS (TLS 1.2+/1.3), including remote control (secure WebSocket).
- **Pairing proves the certificates.** The 6-digit code runs through **SPAKE2**, a password-authenticated key exchange, together with both devices' certificate fingerprints. If someone sat in the middle, the two devices would see different certificates and the exchange fails. Watching the pairing doesn't help anyone guess the code offline: each guess needs a live attempt, and there are only 5.
- **After pairing, each device only accepts the other's exact certificate** (pinning). An impostor at the same address is refused.
- **Bluetooth** has no TLS, so every request and response between paired devices is sealed with **AES-256-GCM** under a key both sides got from pairing. Requests carry a timestamp and a one-time nonce, so recorded traffic can't be replayed.
- **Keys stay protected on each device:** this device's private key and the pairing tokens and keys live in the Keychain (iPhone), the Android Keystore, or DPAPI-protected storage (Windows). On a Mac they're in a file only your macOS account can read (`~/Library/Application Support/…/secrets.json`, permissions 600, like SSH keys): the Keychain kept asking for your password because the Mac app isn't signed with a paid Apple account, so Sidekick never touches it. A Mac updated from 1.0.0 or 1.0.1 starts with a new key; its paired devices show **Pair again**.
- **Check it yourself:** Settings → Paired devices → tap a device shows a 12-digit **security code**. The other device shows the same code for you only if nobody is in between.
- **What isn't hidden:** device names and types in discovery (so you can find each other) and the pairing request itself.
- Updating from 0.2 to 0.3: devices you paired before have to be **paired again once**, and both devices need 0.3 or newer.
- **Media control** uses Windows' Global System Media Transport Controls, the same thing behind the volume flyout, so it works with Spotify, browsers, VLC, the Media Player app and so on. If that helper can't start, play/pause, next/previous and volume still work through media keys.

### Known limits

- **Not tried on real devices yet.** The code is analyzed and unit-tested (pairing, auth, files, media and input protocol), and CI builds the Windows installer and the APK. But the Windows input and media helper, and the Android accessibility and media code, need real hardware to confirm.
- **The phone has to be running Sidekick** (it can be in the background) for the PC to reach it. Android may stop it after a long time in the background.
- **Sharing from other apps** (Share → Sidekick) isn't in yet on Android or iOS. Use **Send** in Sidekick.
- **The macOS and iOS apps aren't signed or notarized**, since that needs a paid Apple Developer account. See Install above for how to open them.
- **Windows won't let Sidekick control elevated (admin) windows**, such as Task Manager, unless Sidekick itself runs as administrator.
- **There's no screen view**, so you control the other device by looking at it (fine for media and presentations).

### Development

```sh
cd app
flutter analyze
flutter test                              # protocol tests (run anywhere)
flutter test tool/screenshots_test.dart   # renders every tab to build/screenshots/
python tool/make_icons.py                 # rebuilds all app icons from website/1.png and 3.png
```

## Website

`index.html` (at the top of the repo) is a self-contained landing page built with Material You (Material 3). It has:

- Dynamic color: every color comes from a single seed hue, so the swatches recolor the whole page.
- Light and dark themes that follow your system setting, plus a manual toggle.
- A working demo in the hero: the phone's media controller drives the "video" on the laptop.
- A touchpad demo and a file-browser demo in the features section.

Its icons live in `website/` and are linked as `/website/…`, so serve the repo's top folder (GitHub Pages, Netlify or Cloudflare Pages), or preview it with `python3 -m http.server` from there and open http://localhost:8000.

> The waitlist form is a placeholder. Hook it up to Formspree, Buttondown, Supabase, or similar (search for `TODO` in the file).

## Recommended stack

**Flutter with Dart**, plus small native plugins where the operating system requires them.

Why Flutter fits:

- **Material 3 is the default design system.** `useMaterial3: true` together with the [`dynamic_color`](https://pub.dev/packages/dynamic_color) package gives you real Material You wallpaper colors on Android and an accent color on desktop.
- **One codebase covers all four targets:** Android, iOS, Windows, and macOS (and Linux).
- **LocalSend is built with Flutter** and is open source (Apache-2.0), so you can study how it handles device discovery and file transfer.

### Architecture

```
┌──────────── Flutter UI (Material 3, shared) ────────────┐
│ Devices · Files · Remote · Media                        │
├──────────────── Core (pure Dart, shared) ───────────────┤
│ Discovery (mDNS + UDP multicast)                        │
│ Pairing (QR code → exchange TLS certificates)           │
│ Transport: HTTPS for files, WebSocket for control/events│
│ Protocol: JSON messages, versioned                      │
├──────── Platform plugins (per OS, via Pigeon/FFI) ──────┤
│ Input injection │ Media sessions │ Screen capture       │
└─────────────────────────────────────────────────────────┘
```

| Feature | Android | iOS | Windows | macOS |
|---|---|---|---|---|
| Discovery and pairing | mDNS (`nsd` package) | mDNS (Bonjour) | mDNS | Bonjour |
| File transfer | HTTPS server/client (`shelf`, `dio`) | same | same | same |
| Browse remote files | SAF / all-files access | App sandbox + Files app | Full file system | Full file system (with user permission) |
| **Control this device** | `AccessibilityService.dispatchGesture` | — (not in the iOS app) | `SendInput` (Win32 via FFI) | `CGEvent` (needs Accessibility permission) |
| **Stream this device's screen** | `MediaProjection` | — (not in the iOS app) | Desktop Duplication / `screen_capturer` | ScreenCaptureKit |
| **Media control of this device** | `MediaSessionManager` + notification listener | — (not in the iOS app) | `GlobalSystemMediaTransportControls` (SMTC) | `MediaRemote` (private) / AppleScript fallback |
| Video for remote screen | `flutter_webrtc` | same | same | same |

**iOS scope:** the iOS app only controls the PC (remote, files, media). It doesn't include being controlled, screen sharing, or media control of the iPhone itself. iOS doesn't allow third-party apps to do these, so none of the iOS-side plugins are needed.

### Suggested build order

1. **Discovery, pairing, and file send.** The LocalSend-style core. Ship this first, since it's useful on its own.
2. **Media controller** (PC side first: SMTC on Windows, MediaRemote on macOS). High payoff for little work.
3. **Phone → PC remote:** touchpad and keyboard only (input injection, no video yet).
4. **Remote file browser.**
5. **Screen streaming with WebRTC**, then Android → be controlled from the PC.

### Useful packages

`dynamic_color`, `go_router`, `riverpod`, `nsd` or `bonsoir` (mDNS), `shelf` (HTTP server), `dio`, `web_socket_channel`, `mobile_scanner` (QR), `qr_flutter`, `file_picker`, `flutter_webrtc`, `pigeon` (native bridges), `window_manager`, `tray_manager` (desktop tray icon).

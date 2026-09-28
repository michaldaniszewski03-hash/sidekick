# Sidekick

Sidekick combines LocalSend and KDE Connect in one app. It links your phone and computer over your local network so you can:

- **Remote control, both ways:** use your phone as a touchpad and keyboard for your PC, or control your Android phone from your PC.
- **Browse files:** open the other device's storage and pull files across.
- **Share files:** send files of any size with drag and drop or the share sheet. No cloud involved.
- **Control media:** play, pause, seek, skip, and change the volume of whatever is playing on the other device.

Platforms: **Android, iOS, Windows, macOS** (Linux comes almost free with the same stack).

## Windows app (v0.1)

The Flutter app lives in `app/`. Windows is the first target; the same code will later build for Android, macOS and iOS.

### Get it running

**Download a build:** every push runs the **Windows app** workflow on GitHub Actions. Open the latest run, download `sidekick-windows-x64`, unzip it, and run `sidekick.exe`.

**Or build it yourself** on a Windows PC:

1. Install [Flutter](https://docs.flutter.dev/get-started/install/windows/desktop) and Visual Studio 2022 with the **Desktop development with C++** workload.
2. Run:
   ```sh
   cd app
   flutter pub get
   flutter run -d windows
   ```

The first time Sidekick starts, Windows Firewall asks whether to allow it. Choose **Private networks**, otherwise other devices can't find it.

**Trying it without a phone:** run Sidekick on two Windows PCs on the same Wi-Fi. They find each other, you pair them, and each can control the other.

### What works

| Tab | What it does |
|---|---|
| **Devices** | Finds Sidekick devices on your Wi-Fi, pairs with a 6-digit code, **Add by IP** if discovery is blocked, drag files onto a device card to send them |
| **Files** | Browse the other device's folders and drives, download files, upload into the open folder (button or drag and drop), transfer progress |
| **Remote** | Touchpad (drag to move, click, right-click, scroll), a **Hold** toggle for dragging, live keyboard capture, a send-text box, shortcuts (Alt+Tab, Win+D, Ctrl+C/V…) |
| **Media** | Title, artist and app of whatever's playing, play/pause, previous/next, ±10 s, a seek bar, a volume slider, mute |
| **Settings** | Device name, the folder received files go to, switches for what paired devices may do, light/dark mode |

When a paired device is controlling this PC, a banner says so, with a button that unpairs it and stops the session right away.

### How it works

```
app/lib/
├── main.dart            Material 3 theme (uses the Windows accent color)
├── app_state.dart       all app state: devices, pairing, transfers, settings
├── core/
│   ├── models.dart      JSON types shared by every platform
│   ├── discovery.dart   UDP multicast announcements (224.0.0.168:53318)
│   ├── server.dart      HTTP + WebSocket server every device runs (port 53318)
│   ├── client.dart      talks to another device's server
│   └── trust.dart       pairing codes, tokens, trusted devices
├── platform/
│   ├── input.dart       mouse/keyboard via Win32 SendInput (dart:ffi)
│   ├── media.dart       Windows media sessions + volume via a PowerShell helper
│   └── files.dart       folder listing, safe file names
└── ui/                  one file per tab
```

- **Pairing:** device A asks B to pair; B shows a 6-digit code; you type it on A. Both devices then hold a random token for each other. Pairing works both ways, so either device can control the other. After 5 wrong codes, or 2 minutes, the code stops working.
- **Every request except `/v1/info` and pairing needs a token.** Unpairing revokes the token straight away, including any live remote-control session.
- **Media control** uses Windows' Global System Media Transport Controls, the same thing behind the volume flyout, so it works with Spotify, browsers, VLC, the Media Player app and so on. If that helper can't start, play/pause, next/previous and volume still work through media keys.

### Known limits (v0.1)

- **Not tried on a real Windows PC yet.** The code is analyzed and unit-tested (pairing, auth, files, media and input protocol), and CI builds it on Windows. But `SendInput` and the media helper need a real Windows machine to confirm.
- **Traffic is plain HTTP on your local network.** Tokens stop strangers from controlling your PC, but someone on the same Wi-Fi could read the traffic. The next security step is TLS with the certificate fingerprint pinned during pairing.
- **Windows won't let Sidekick control elevated (admin) windows**, such as Task Manager, unless Sidekick itself runs as administrator.
- **There's no screen view yet**, so you control the PC blind (fine for media and presentations). Screen streaming with WebRTC is next.

### Development

```sh
cd app
flutter analyze
flutter test                              # protocol tests (run anywhere)
flutter test tool/screenshots_test.dart   # renders every tab to build/screenshots/
```

## Website

`website/index.html` is a self-contained landing page built with Material You (Material 3). It has:

- Dynamic color: every color comes from a single seed hue, so the swatches recolor the whole page.
- Light and dark themes that follow your system setting, plus a manual toggle.
- A working demo in the hero: the phone's media controller drives the "video" on the laptop.
- A touchpad demo and a file-browser demo in the features section.

To preview it, open the file in a browser. To host it, publish the `website/` folder with GitHub Pages, Netlify, or Cloudflare Pages.

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

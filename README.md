# Sidekick

Sidekick combines LocalSend and KDE Connect in one app. It links your phone and computer over your local network so you can:

- **Remote control, both ways:** use your phone as a touchpad and keyboard for your PC, or control your Android phone from your PC.
- **Browse files:** open the other device's storage and pull files across.
- **Share files:** send files of any size with drag and drop or the share sheet. No cloud involved.
- **Control media:** play, pause, seek, skip, and change the volume of whatever is playing on the other device.

Platforms: **Android, iOS, Windows, macOS** (Linux comes almost free with the same stack).

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

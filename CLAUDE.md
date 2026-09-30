# Sidekick

Use your phone and computer as one: send files both ways, control one device
from another (touchpad, keyboard, shortcuts), and connect over Bluetooth
when there's no shared Wi-Fi. Everything is encrypted.

One Flutter app for **Windows, macOS, Android and iOS** (`app/`), plus a
download page (`index.html` at the top of the repo, not hosted anywhere
yet; its images live in `website/` and it links them as `/website/…`).

**Every change must work on all four platforms.**

## Keeping this file up to date

**Every release adds an entry to [Versions](#versions)** (newest first) with
its biggest features and fixes, and bumps the website links (see
[Releasing](#releasing)). The history starts at 1.1.3.

## Layout

- `app/lib/app_state.dart`: the app's state (paired and nearby devices,
  transfers, settings), and sending and receiving.
- `app/lib/core/`: platform-independent logic, unit-tested.
  - `server.dart`: HTTPS server on port 53318 (the same handler also serves
    Bluetooth). Pairing, files, transfer offers and tickets, input.
  - `client.dart`: `PeerClient`, over HTTPS (pinned certificate) or Bluetooth.
  - `crypto.dart`: identity certificates, SPAKE2 pairing, AES-GCM sealing,
    security codes.
  - `ble_protocol.dart`: Bluetooth message framing, chunking, sealing, and
    the request dispatcher.
  - `bluetooth.dart`: `BluetoothService` (scan, identify, links,
    candidates, the pairing search).
  - `ble_backend.dart`: the radio behind it. `AppleBleBackend` talks over
    channels to `SidekickBLE.swift` (CoreBluetooth). `PluginBleBackend` uses
    the `bluetooth_low_energy` plugin on Android and Windows.
- `app/lib/ui/`: screens. `transfer_screens.dart` holds the sender's full
  screen and the receiver's Accept/Decline card.
  - `startup.dart`: the startup animation (every platform; a tap skips it,
    reduced motion turns it off).
  - `widgets.dart` has the shared pieces: `PageFrame`, `SectionLabel` (with
    an icon), `IconTile` (tinted icon square for rows), `StatusPill`,
    `Entrance` (fade/slide-in cascade), `Radar` (searching), `GradientBadge`.
- `app/lib/platform/`: per-OS glue (input, files, device names,
  secret storage, hotspot, and the startup chime in `sound.dart`: afplay on
  Mac, PlaySound on Windows, `playSound` on the `sidekick/ios` and
  `sidekick/android` channels; the Mac uses NSSound on `sidekick/macos`).
  The sounds are the owner's own recordings in `app/tool/sounds/` (MP3),
  turned into `app/assets/sounds/*.wav` by `app/tool/prepare_sounds.py`
  (WAV: Windows PlaySound and iPhone system sounds can't play MP3; silence
  trimmed, soft fades, equal loudness). `appstartupchime` → startup.wav
  (launch), `newfilesendrequest` → request.wav (Accept/Decline card
  appears), `filerequest_accept` → accept.wav and `filerequest_deny` →
  decline.wav (on both devices: the one tapping and the sender getting the
  answer). One switch for all of them: Settings → Sound ("Sound enabled" /
  "Sound disabled"; `AppState.sound`, pref `sound`). Don't synthesize
  replacements.
- Native code:
  - `app/ios/Runner/SidekickBLE.swift` and `app/macos/Runner/SidekickBLE.swift`
    must stay **identical** (copy one to the other after any edit).
  - `AppDelegate.swift` (iOS) and `MainFlutterWindow.swift` (macOS) register
    the channels.
  - The Windows runner compiles C++ with `/W4 /WX`.
- `app/macos/packaging/`: the .dmg background (1x and 2x).
- Logos (`website/`): `2.png` is the wide wordmark, used **only on the
  website**; `3.png` is the "sk" monogram, used for every app icon and the
  logo inside the app (`app/assets/logo/logo.png`). `app/tool/make_icons.py`
  regenerates all of them; re-run it after changing 3.png.
  - Mac and iPhone icons are Liquid Glass: `Runner/AppIcon.icon` (Icon
    Composer format, in both Xcode projects' Resources) is what macOS/iOS
    26+ show, rendered live by the system (Dark, Clear, Tinted too). The
    `AppIcon.appiconset` PNGs are a pre-rendered glass look for older
    systems. Both come from `make_icons.py`; Xcode 26 (CI) builds the .icon.
  - The website's tab icon (`website/favicon.png`) and home-screen icon
    (`website/apple-touch-icon.png`) are the same glass "sk", also from
    `make_icons.py`.
- Mac: the file picker (`file_picker`) needs the
  `files.user-selected.read-write` entitlement and `prepareFilePicker()`
  (skips its sandbox check), or Send files silently does nothing.
- `.github/workflows/build.yml`: CI and releases.

## Conventions

- Flutter is at `/home/user/tools/flutter/bin`. The UI library is
  `material_ui`.
- Format with `dart format -l 120`. Before pushing, `flutter analyze` must
  report no issues and `flutter test` must pass.
- Screenshots without a device:
  - `flutter test tool/screenshots_test.dart` renders the tabs.
  - `flutter test tool/transfer_shots_test.dart` renders the send and
    receive screens.
  - The first also renders the startup animation as `startup-NN.png`
    frames (50 ms apart).
  - Output goes to `build/screenshots/`.
- Swift can't be compiled here. CI (`ios` and `macos` jobs) is the check.
- Bluetooth:
  - Writes are always one packet (MTU minus 3), never long writes.
  - Files go over Bluetooth in 32 KB sealed parts (`/v1/fs/upload/part`),
    each retried if it arrives damaged ("Message failed authentication"),
    never as one giant message: one bad packet in a multi-MB message used
    to fail the whole file. Older receivers get the whole file (fallback).
  - Message ids start at a random number per client, so two clients on one
    connection never mix their chunks.
  - Sealed messages carry `kid` (a short fingerprint of the pairing key).
    A mismatch is refused as "Pairing keys don't match" and the app shows
    "Pair again"; a failed decrypt with the same key means a damaged packet.
    Every refusal is written to the receiver's Bluetooth log.
- Devices announce their release (`DeviceInfo.app`, "2.2.0"); a paired card
  shows "Update Sidekick on it" when the other device runs an older one.
- There is no Media feature (removed in 2.2.0: iPhones can't control other
  apps' playback). Don't bring it back.
  - iPhone and Mac use native CoreBluetooth, not the plugin: the plugin
    reported no devices on Apple.
  - Windows advertises through `addService` only. Its advertiser rejects
    service IDs.
- Mac secrets live in a 0600 file, never the keychain (an unsigned app gets
  endless keychain password prompts).
- Develop on `claude/sidekick-app-architecture-8ilytw`.

## Releasing

1. Push to the branch. CI runs tests and builds all four platforms.
2. Run the `Build` workflow (workflow_dispatch) with `release_tag: vX.Y.Z`.
   It builds everything and publishes the release: `SidekickSetup-X.Y.Z.exe`,
   `Sidekick-X.Y.Z.dmg`, `Sidekick-X.Y.Z.apk`, `Sidekick-X.Y.Z.ipa`,
   `altstore.json`.
3. Update `index.html` (every `X.Y.Z` link, `version:` and "Version
   X.Y.Z").
4. Add the version to [Versions](#versions) below.

## Versions

### 2.4.1
- **The owner's own sounds:** app startup, a new file request, request
  accepted and request declined (`tool/sounds/`, prepared into WAV by
  `tool/prepare_sounds.py`: trimmed, soft fades, equal loudness). Accept and
  decline play on both devices. Replaces the synthesized chimes.
- **One Sound switch** in Settings for all of them: "Sound enabled" /
  "Sound disabled".

### 2.4.0
- **Playful request chime:** a bouncy "ba-da-ding" when the Accept/Decline
  card appears, on all four platforms (Settings → Request sound, with a
  Play button).
- **Livelier Accept/Decline card:** the app behind blurs and the card
  springs up; its contents cascade in; the device circle breathes and
  "knocks"; the file chip flies in; Accept glows; the countdown turns red
  near the end; confetti on Accept and when everything has arrived.
- **Website tab icon:** favicon and home-screen icon, the glass "sk".

### 2.3.1
- **The startup chime plays:** from `main()`, no longer tied to the
  animation (which "Reduce motion" skips); on the Mac through NSSound
  (`sidekick/macos` → `playSound`), `afplay` only as a fallback.
  Settings → Startup sound has a Play button to hear it any time.
- **Visible icon on the receive card:** the device icon was fixed white on
  the theme's gradient, invisible in dark mode with the black-and-white
  theme; it now uses the theme's matching color.

### 2.3.0
- **New startup chime, on every device:** a soft lift, two mallet notes and
  a warm chord that blooms with the animation (stereo, ~2 s). Mac: afplay;
  Windows: PlaySound; iPhone: a system sound (follows the silent switch);
  Android: a UI sound (follows silent mode). Settings → Startup sound on
  all four.
- **Stability:**
  - Startup never ends on a blank window: a failure shows "Sidekick
    couldn't start" with Try again; bad saved settings, a failing device
    name lookup or any server start error no longer stop the app.
  - Unexpected errors are logged instead of crashing; a part that fails to
    draw shows a short note instead of a red screen.
  - Discovery rejoins the network when it changes (Wi-Fi switch, waking
    from sleep), so devices stop vanishing until a restart; the shown IP
    address updates too.
  - Phones coming back from the background check the server still
    answers and restart it (and discovery) if the system closed them.
  - Stricter checks (`unawaited_futures`, `use_build_context_synchronously`).

### 2.2.0
- **Liquid Glass app icon on Mac and iPhone:** an Icon Composer icon
  (`AppIcon.icon`) that macOS/iOS 26+ render as live glass (Dark, Clear and
  Tinted too); older systems get a pre-rendered glass version.
- **Media removed** (tab, device-card shortcut, Settings switch, Android
  notification access, native media code): iPhones can't control other
  apps' playback, so it never worked the same everywhere.
- **Bluetooth "Message failed authentication" says what to do:**
  - Devices announce their Sidekick release; a paired card shows "Update
    Sidekick on it" when the other one is older, and failed sends say so.
  - Different pairing keys are detected (key fingerprint in every sealed
    message) and shown as "Pair again" instead of endless retries.
  - Every refused Bluetooth message is logged on the receiver with why.

### 2.1.2
- **Sending photos and files over Bluetooth works reliably** (iPhone → Mac
  failed with "Message failed authentication"): files go in 32 KB sealed
  parts, each checked on arrival and resent if a packet got damaged,
  instead of one multi-MB message that one bad packet could fail.
  - Big messages are no longer refused for taking longer than 2 minutes.
  - Message ids start at random per client, so parallel clients can't mix
    chunks; re-pairing takes effect right away over Bluetooth.
  - If it still fails, the error says what it means (and to re-pair).

### 2.1.1
- **"Connect device"** (was "Add device") on the Devices tab, with plain
  options: **Wi-Fi**, **Bluetooth** and **IP address**, each with one short
  line on when to use it.

### 2.1.0
- **Startup animation** on every platform: the "sk" tile pops in, ripples
  spread, the name rises, then it zooms away into the app. A tap skips it;
  reduced motion turns it off.
- **Startup chime on the Mac** (Settings → Startup sound, on by default).
- **Simpler:** Devices has one "Add device" menu (Search Wi-Fi, Pair over
  Bluetooth, Add by IP); Settings descriptions are one short line each.
- **More icons:** tinted icon tiles on every Settings row, icons on section
  labels, Wi-Fi/Bluetooth/offline icons in status pills, icons on snackbars.
- **More motion:** cards, groups, empty states and file rows cascade in; tab
  switches slide and fade; a new track slides in on Media; a radar while
  looking for devices; device cards lift on hover.

### 2.0.2
- **Send files works on the Mac again:** the Mac file picker refused to open
  without a sandbox file entitlement (Sidekick isn't sandboxed) and the
  error was swallowed. The entitlement is declared, the check is skipped on
  Mac, and a picker that can't open now says why. Also fixes Settings →
  "Save received files to → Change" on the Mac.
- **"sk" logo inside the app:** the side rail and welcome screen show the
  monogram (3.png); the wide wordmark stays on the website only.

### 2.0.1
- **App icons are the "sk" monogram** (`website/3.png`) everywhere the
  system shows Sidekick: Mac dock, Windows desktop/taskbar/Start menu and
  installer, Android and iPhone home screens, at every size, with a little
  more breathing room around it. The website keeps the wide wordmark
  (`website/2.png`), and so does the logo inside the app.
- The logo inside the app is 10 px smaller (welcome screen 206 px wide,
  desktop side rail 66 px).

### 2.0.0
- **New logo:** the wide SIDEKICK wordmark (`website/2.png`) on app icons
  (replaced by the "sk" monogram in 2.0.1), in the app and on the website.
- **Redesign, still Material You** (wallpaper/theme colors unchanged):
  - One app-wide theme (`main.dart`): bold headlines, soft 16–28 px shapes,
    44 px buttons, rounded outlined fields, check icons on switches, the
    current Material 3 progress bars and sliders, floating rounded
    snackbars, restyled navigation rail/bar, fade-forward page transitions
    on Android/Windows, and a fade-through between tabs.
  - Pages (`PageFrame`) get a subtitle line (e.g. "1 paired · 1 connected")
    and never stretch wider than 1080 px on big screens.
  - Devices: a gradient "This device" hero card with Wi-Fi and Bluetooth
    status pills; paired cards with a status pill, one "Send files" button
    and icon shortcuts to Files, Remote and Media.
  - Shared pieces: `GradientBadge` (the signature icon tile) and
    `StatusPill`. Empty states use the gradient tile.

### 1.1.3
- **Styled Mac installer:** the .dmg opens on the purple background with an
  arrow; drag Sidekick (right) into Applications (left).
- Everything from the 1.1 line, which is where the history starts:
  - **Bluetooth that works on Apple:** iPhone and Mac use Sidekick's own
    CoreBluetooth code (`SidekickBLE.swift`). Mac ↔ iPhone pairing and
    transfers work with no Wi-Fi.
  - **Bluetooth on Windows:** Windows now finds devices (a subscription
    Windows doesn't support used to abort setup) and can be found
    (advertises through the GATT service).
  - **Bluetooth look-alikes filtered:** only devices that really advertise
    Sidekick are listed. Apple's shared background bitmask no longer shows
    random devices.
  - **Clear Bluetooth problems:**
    - An old system pairing ("Peer removed pairing information") says to
      forget the device in Bluetooth settings.
    - Windows' LE service being off (0x80070422) lists what to check.
    - Both have Settings buttons.
  - **Ask before receiving:** the sender sees a full-screen "Waiting for
    permission…", then a progress ring and bar, then Sent / Declined / No
    answer, and it closes by itself. The receiver gets an animated
    Accept/Decline card with a countdown and live progress.
    - Uploads to the receive folder need a ticket from an accepted offer.
    - Settings → "Ask before receiving files" (on by default).
  - **Live progress over Bluetooth** on both sender and receiver.

# Sidekick

Use your phone and computer as one: send files both ways, control one device
from another (touchpad, keyboard, shortcuts), control media and volume, and
connect over Bluetooth when there's no shared Wi-Fi. Everything is encrypted.

One Flutter app for **Windows, macOS, Android and iOS** (`app/`), plus a
download page (`website/index.html`, not hosted anywhere yet).

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
    Bluetooth). Pairing, files, transfer offers and tickets, media, input.
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
- `app/lib/platform/`: per-OS glue (input, media, files, device names,
  secret storage, hotspot).
- Native code:
  - `app/ios/Runner/SidekickBLE.swift` and `app/macos/Runner/SidekickBLE.swift`
    must stay **identical** (copy one to the other after any edit).
  - `AppDelegate.swift` (iOS) and `MainFlutterWindow.swift` (macOS) register
    the channels.
  - The Windows runner compiles C++ with `/W4 /WX`.
- `app/macos/packaging/`: the .dmg background (1x and 2x).
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
  - Output goes to `build/screenshots/`.
- Swift can't be compiled here. CI (`ios` and `macos` jobs) is the check.
- Bluetooth:
  - Writes are always one packet (MTU minus 3), never long writes.
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
3. Update `website/index.html` (every `X.Y.Z` link, `version:` and "Version
   X.Y.Z").
4. Add the version to [Versions](#versions) below.

## Versions

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

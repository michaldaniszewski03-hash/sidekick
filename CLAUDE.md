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
  - `pairing_qr.dart`: what pairing QR codes say. `sidekick://pair?…` (an
    invite: id, name, addresses, port, certificate fingerprint, one-time
    secret) and `sidekick://pin?id=&c=` (the 6-digit code as a QR).
  - `ble_protocol.dart`: Bluetooth message framing, chunking, sealing, and
    the request dispatcher.
  - `bluetooth.dart`: `BluetoothService` (scan, identify, links,
    candidates, the pairing search).
  - `ble_backend.dart`: the radio behind it. `AppleBleBackend` talks over
    channels to `SidekickBLE.swift` (CoreBluetooth). `PluginBleBackend` uses
    the `bluetooth_low_energy` plugin on Android and Windows.
- `app/lib/ui/`: screens. `transfer_screens.dart` holds the sender's full
  screen and the receiver's Accept/Decline card.
  - `qr_pairing.dart`: pairing by QR code (Connect device → QR code).
    Every device can show its code; only iPhone and Android scan
    (`mobile_scanner`). Mac and Windows never offer scanning (the owner's
    call: their cameras can't scan another screen); they show codes and
    type the 6 digits. **One QR code for everything** (the owner's call):
    every QR Sidekick shows is the same invite (`sidekick://pair?…`), on
    Connect device → QR code and next to the 6 digits (when the other
    device is a phone); scanning it pairs on its own, from either
    scanner. `sidekick://pin` is only still read, from older releases.
  - `corner_popup.dart`: the small window in the bottom-right corner on
    Windows and Mac (360×150) when a request arrives while Sidekick is in
    the tray: Accept / Decline, then a progress bar; it closes by itself
    as soon as the files are in, or at once on Decline.
  - `startup.dart`: the startup animation (every platform; a tap skips it,
    reduced motion turns it off).
  - `widgets.dart` has the shared pieces: `PageFrame`, `SectionLabel` (with
    an icon), `IconTile` (tinted icon square for rows), `StatusPill`,
    `Entrance` (fade/slide-in cascade), `Radar` (searching), `GradientBadge`.
- `app/lib/platform/`: per-OS glue (input, files, device names,
  secret storage, hotspot, and the sounds in `sound.dart`: PlaySound on
  Windows, `playSound` on the `sidekick/macos`, `sidekick/ios` and
  `sidekick/android` channels). Mac and iPhone use AVAudioPlayer, Android
  MediaPlayer, all on the media volume and held until they finish (not
  iPhone system sounds: muted by the silent switch). The WAV is copied to
  the temp folder first; on the Mac that's `~/Library/Caches/<app id>`,
  which must be created (it wasn't, and the Mac never played a sound).
  The sounds are the owner's own recordings in `app/tool/sounds/` (MP3),
  turned into `app/assets/sounds/*.wav` by `app/tool/prepare_sounds.py`
  (WAV: Windows PlaySound can't play MP3; silence
  trimmed, soft fades, equal loudness). `appstartupchime` → startup.wav
  (launch), `newfilesendrequest` → request.wav (Accept/Decline card
  appears), `filerequest_accept` → accept.wav and `filerequest_deny` →
  decline.wav (on both devices: the one tapping and the sender getting the
  answer). One switch for all of them: Settings → Sound ("Sound enabled" /
  "Sound disabled"; `AppState.sound`, pref `sound`). Don't synthesize
  replacements.
- `platform/desktop_window.dart` (Windows, Mac; `window_manager`,
  `tray_manager` 0.5.x: 0.6+ is a native-library rewrite): closing the
  window hides it to the tray / menu bar (Open, Quit); a request then
  shows [CornerPopup] instead of the app (main.dart `_withCornerPopup`),
  the window put back afterwards. While hidden, animations are paused.
  **Never call `setSkipTaskbar`** (or anything else using the plugin's
  taskbar object) on Windows: it's only created in `waitUntilReadyToShow`,
  so it's a null pointer and the app crashes (2.6.2 crashed this way when a
  request arrived in the tray).
  Tray icons: `assets/tray/` and Android's `ic_stat_sidekick`, from
  `make_icons.py` (`tray()`).
- `platform/notifications.dart` (phones): a request while Sidekick isn't on
  screen becomes a notification with Accept / Decline (`notifyOffer`;
  the buttons come back as `offerAction`). Android: `Notifications.kt`
  (also the progress and "Received"), `OfferActionReceiver`, and
  `SidekickService`, a foreground service (connectedDevice, stopWithTask)
  with a small "Ready to receive" notification; Back on the last screen
  sends Sidekick to the background instead of closing it. iPhone:
  `OfferNotifier` in AppDelegate.swift (only while it runs in the
  background; iOS stops apps that are swiped away). The in-app card follows
  answers given there.
- The "open" button (folder icon) on received files and on the
  "Received" snackbar: Explorer/Finder on computers; on phones the Files
  app at the folder (`openFolder`: iPhone `shareddocuments://`, Android
  DocumentsContract, Download/Sidekick), or Photos / the gallery for photos
  and videos (`openGallery`; Android returns the MediaStore uri from
  `saveToGallery`).
- Screens close themselves with `closeRoute` (their own route, never
  "whatever's on top": that closed the wrong thing and left the sending
  screen's Close button dead).
- Photos and videos a phone receives (sent to it, or downloaded from the
  other device's files) go straight to Photos / the gallery, automatically,
  like AirDrop (the owner's call: no switch). `platform/gallery.dart` picks
  which files (`Gallery.kindOf`) and calls `saveToGallery` on
  `sidekick/ios` (`PhotosSaver`: add-only access, the file is moved in) and
  `sidekick/android` (MediaStore, Pictures/Sidekick and Movies/Sidekick,
  on a worker thread; the original is deleted after). Files a computer
  copies into a folder it browsed to stay there (`FileReceived.
  toReceiveFolder`). If saving fails, the file stays in the receive folder
  and the notice says why.
- Native code:
  - `app/ios/Runner/SidekickBLE.swift` and `app/macos/Runner/SidekickBLE.swift`
    must stay **identical** (copy one to the other after any edit).
  - `AppDelegate.swift` (iOS) and `MainFlutterWindow.swift` (macOS) register
    the channels.
  - The Windows runner compiles C++ with `/W4 /WX`.
- `app/macos/packaging/`: the .dmg background (1x and 2x), and `pkg/`: the
  .pkg installer's welcome page and corner icon (glass "sk", 1x and 2x).
  Macs get both: the .dmg (drag to Applications) and the .pkg (installs
  into /Applications). CI builds the .pkg with pkgbuild/productbuild.
- Privacy policy: `privacy.html` at the top of the repo (the website) and
  `app/packaging/privacy.txt` (shown by the Windows installer before
  installing, installed as `Privacy.txt`, and the .pkg's second page). Keep
  the two saying the same thing, and true: no account, no servers, no
  analytics; what's stored on the device; what's announced to nearby
  devices; every permission and why.
- Website hero (`website/hero.webp`, `hero.png` fallback): a MacBook
  receiving and an iPhone sending, made from the ad render frames
  (`tool/ad_frames_test.dart`), transparent so the page's colors show.
  There is no Media anywhere on the site (removed with the feature).
- Website sounds (`website/sounds/`, copies of the owner's MP3s): the
  request sound when the demo phone asks, accept / decline on its buttons,
  accept on a download; only after a click; the speaker button in the top
  bar turns them off (`localStorage` `sidekick-sound`).
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
  - `flutter test tool/qr_shots_test.dart --plain-name mac` (then
    `iphone`, with `SIDEKICK_CAMERA=` a picture for the camera) renders the
    QR pairing screens at 2x/3x for ads; `SIDEKICK_FONTS=` a folder of
    Inter TTFs stands in for San Francisco.
  - `flutter test tool/ad_frames_test.dart` renders the startup animation,
    an iPhone sending and the Mac's Accept card as 30 fps frames
    (`build/ad/<scene>/NNN.png`) for video ads. `SIDEKICK_THEME=mono`
    renders both tools in the Monochrome theme. `SIDEKICK_DPR=4` renders
    the Mac scene at 4x (`receive@4x`), sharp enough to zoom into in 4K.
    `--plain-name "remote iphone"`, then `"remote mac"` (run separately,
    or the iPhone shows up in the Mac's Nearby list), saves stills of a
    paired iPhone's Remote tab and the Mac's Devices tab, paired with a
    real loopback stand-in.
  - Output goes to `build/screenshots/`.
- Swift can't be compiled here. CI (`ios` and `macos` jobs) is the check.
- Bluetooth:
  - **Off by default** (the owner's call): Settings → Bluetooth turns it
    on (`AppState.bluetoothOn`, pref `bluetooth`); until then Sidekick
    never starts the radio, so no permission prompt at start. Picking
    Bluetooth in Connect device asks to turn it on.
  - **Wi-Fi first** (the owner's call): while this device is on Wi-Fi
    (`lanAddresses`: private ranges on real Wi-Fi/Ethernet interfaces,
    not mobile data, VPNs or virtual adapters) Bluetooth is never used,
    unless the other device says it isn't on Wi-Fi (`DeviceInfo.wifi`,
    sent over Bluetooth). "Not on Wi-Fi" needs two checks in a row. On
    Wi-Fi, Bluetooth scans once a minute at most.
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
- Pairing is SPAKE2 with either the 6-digit code or a QR invite's secret
  (`PairingInvite`: 5 minutes, one device, closed with the dialog). The
  scanner only talks to the address that presents the QR code's
  certificate fingerprint, and falls back to Bluetooth. Camera: iOS
  `NSCameraUsageDescription`; Android's permission comes from the plugin.
  The Mac has no camera permission (it never scans).
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

The owner wants finished work released right away: once a feature or fix
is done and CI is green, release it (next patch version unless they name
one) without asking.

1. Push to the branch. CI runs tests and builds all four platforms.
2. Run the `Build` workflow (workflow_dispatch) with `release_tag: vX.Y.Z`.
   It builds everything and publishes the release: `SidekickSetup-X.Y.Z.exe`,
   `Sidekick-X.Y.Z.dmg`, `Sidekick-X.Y.Z.pkg`, `Sidekick-X.Y.Z.apk`,
   `Sidekick-X.Y.Z.ipa`, `altstore.json`.
3. Update `index.html` (every `X.Y.Z` link, `version:` and "Version
   X.Y.Z"), including `RELEASE.files.macosPkg` (the `.pkg`).
4. Add the version to [Versions](#versions) below.

## Versions

### 2.6.3
- **Fixed: Windows crashed when a file request arrived while Sidekick was
  in the tray** (the sender saw "Connection reset by peer"). The corner
  window's skip-taskbar call hit a null pointer inside window_manager.
- **Close works on the sending screen again:** Close and Cancel close that
  screen, even if something opened on top of it; Cancel works even as the
  send moves on.
- **Bluetooth is off by default:** Sidekick uses Wi-Fi and doesn't ask for
  Bluetooth at start. Turn it on in Settings → Bluetooth (or when picking
  Bluetooth in Connect device).
- **Open button on phones:** a received file's folder icon opens the Files
  app at its folder; photos and videos open in Photos / the gallery.

### 2.6.2
- **Closing the window keeps Sidekick in the tray** (Windows) / menu bar
  (Mac), still receiving; Open and Quit are there. A file request then
  pops up a **small window in the bottom-right corner** with Accept and
  Decline, then the progress, and closes by itself when the files are in.
- **Notifications on iPhone and Android:** a request while Sidekick is in
  the background shows Accept / Decline; Android also shows the progress
  and keeps a small "Ready to receive" notification while it runs in the
  background (Back no longer closes it).
- **Wi-Fi first:** Bluetooth is only used when one of the devices isn't
  on Wi-Fi (no more Bluetooth while both are).
- **One QR code for everything:** the QR next to the 6-digit code is the
  same pairing code as Connect device → QR code; scanning either pairs.
- **Faster:** themes are built once instead of on every update, and
  nothing animates while the window is in the tray.

### 2.6.1
- **Photos and videos go straight to Photos / the gallery** on iPhone and
  Android, automatically: whatever is sent to the phone, and whatever it
  downloads from the computer. On Android they're in Pictures/Sidekick and
  Movies/Sidekick. Other files stay in the Sidekick folder. The transfer
  shows "in Photos" / "in the gallery".
- iPhone asks once to add to Photos (add-only: Sidekick can't see the
  library). The privacy policy says so.

### 2.6.0
- **A .pkg installer for the Mac**, next to the .dmg: open it, Continue,
  Install, and Sidekick lands in Applications. Its welcome page has the
  glass "sk", and the privacy policy is its second page. The website
  offers it to Mac visitors under the main download.
- **Privacy policy:** on the website (`privacy.html`, linked in the
  footer and under the download), on a page in the Windows installer
  before installing (and installed as `Privacy.txt`), and in the .pkg.
  No account, no servers, no analytics; what stays on the device, what
  nearby devices see, and every permission and why.

### 2.5.1
- **Sounds play on the Mac:** the chime file went to a folder that didn't
  exist on a Mac (`~/Library/Caches/<app id>`), so no sound ever played;
  it's created now, and sounds use AVAudioPlayer.
- **iPhone sounds** use the media volume (system sounds were muted by the
  silent switch); **Android** keeps its player until the sound ends, on
  the media volume.
- Turning Settings → Sound on plays the chime.
- **Only phones scan QR codes:** Mac and Windows just show theirs.

### 2.5.0
- **Pair with a QR code** (Connect device → QR code), alongside the 6-digit
  code:
  - Every device shows a one-time code (5 minutes, one device). iPhone,
    Android and Mac scan it with the camera and pair with nothing to type,
    over Wi-Fi or Bluetooth.
  - The scanner only accepts the device whose certificate is in the code.
  - The 6-digit code screen shows its QR too, and the code entry has
    "Scan the QR code instead".
  - Camera permission on iPhone, Mac and Android.

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

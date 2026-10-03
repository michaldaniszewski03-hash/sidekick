# Sidekick

Use your phone and computer as one: send files both ways, control one device
from another (touchpad, keyboard, shortcuts), and connect over Bluetooth
when there's no shared Wi-Fi. Everything is encrypted.

One Flutter app for **Windows, macOS, Android and iOS** (`app/`), plus a
download page (`index.html` at the top of the repo; its images live in
`website/` and it links them as `/website/…`). The owner hosts it at
https://sk.dankor.digital on cyber_Folks (LiteSpeed), uploading with
FileZilla: `index.html`, `privacy.html`, `404.html`, `.htaccess` and
`website/` go in the subdomain's root folder. `.github/workflows/website.yml`
uploads exactly those over FTPS whenever they change on the branch, once
the owner adds the secrets `FTP_SERVER`, `FTP_USERNAME`, `FTP_PASSWORD` and
`FTP_DIR` (it skips until then). Never put the FTP login anywhere else.

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
    Windows and Mac (380×172) when a request arrives while Sidekick is in
    the tray: Accept / Decline, then a progress bar; it closes by itself
    as soon as the files are in, or at once on Decline. Animated: the
    window rises into its corner (Mac: native fade in `showPopup`, fade
    out in `hidePopup`; Windows: a few `setPosition` steps), the contents
    cascade in, rings ripple from the device badge, a countdown runs along
    the top, a ring fills while receiving, a check pops in, and the
    contents fade out (`CornerPopup.exit`) before `onDone`. Reduced motion
    turns all of it off.
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
  window hides it to the tray / menu bar (Open, Quit). On the Mac the
  close is caught at every step, because 2.6.6 and 2.7.0 still quit on the
  red button: `MainFlutterWindow` (`performClose` and `close` →
  `hideToMenuBar`), window_manager's prevent-close (`onWindowClose` →
  `hideToMenuBar`), and `AppDelegate` never quits after the last window
  while `keepInMenuBar` is on. It's set at start, before the tray icon (the
  Dock icon always brings the window back). Only Quit Sidekick or ⌘Q quits.
  Sidekick stays in the Dock with its dot (the owner's call). The pop-up is shown with `orderFrontRegardless`
  (no focus taken), the window's minimum size lifted while it's up. A
  request then shows [CornerPopup] instead of the app (main.dart `_withCornerPopup`),
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
- `404.html` (top of the repo): the not-found page, for any missing
  address, so every link in it is absolute (`/…`). `.htaccess` makes the
  server show it for every wrong address, keeping the address and a real
  404 status (no redirect); folder listings are off and show it too. Same look and theme
  choice as the site, system fonts only, like `privacy.html`.
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
    **No shadow or edge highlight behind "sk"** (the owner's call: they
    blurred the letters): the .icon's group shadow is `none`, and
    `glass_tile` draws the glyph crisp.
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
- **Direct Wi-Fi for every other pair** (`platform/hotspot.dart`
  `DirectLink`, the owner's call: "make it work for everything"): one
  device opens a small network and the other joins. Opens: Android
  (local-only hotspot), Windows (Wi-Fi Direct "legacy" network through
  PowerShell's WinRT, `-EncodedCommand`; no native code). Joins: Android
  10+ (`WifiNetworkSpecifier`, asks once; `bindProcessToNetwork` so Dart's
  sockets use it), Windows (netsh), Mac (networksetup), iPhone
  (`NEHotspotConfiguration`, needs `Runner.entitlements`' Hotspot
  Configuration, which only signed builds have; otherwise `JoinByHand`:
  the iPhone shows the name and password to join in Settings,
  `ui/direct_wifi.dart`). `directLinkHost` decides who opens it (Android,
  then Windows; two of a kind: the smaller id), tested in
  `test/direct_link_test.dart`. How the two find each other:
  - Bluetooth (the doorbell): a paired device seen over Bluetooth but on no
    shared network is `viaDirectLinkOnly`; sending or Remote sets up the
    link first, even when both are on (different) Wi-Fi networks:
    Bluetooth then never carries the files. Bluetooth is still off by
    default; an unreachable device's card offers "Find nearby", which asks
    to turn it on (`askToTurnOnBluetooth`).
  - A QR code: with no Wi-Fi, an Android phone or PC showing its code opens
    its network first and puts it in the code (`ws`, `wk`, `wt`); the
    scanning phone joins it and pairs (`_reachInviteNetwork`).
  Over Bluetooth (both off Wi-Fi), transfers over 1 MB switch to the link.
- **Direct Wi-Fi between iPhones and Macs** (no router, no Bluetooth):
  Apple's peer-to-peer Wi-Fi (AWDL, AirDrop's link), through the Network
  framework (`includePeerToPeer`). `SidekickP2P.swift` (identical in
  ios/Runner and macos/Runner, like SidekickBLE) advertises
  `_sidekick-p2p._tcp` named after the device id and hands each incoming
  connection to the device's own server on 127.0.0.1; `connect` gives a
  127.0.0.1 port that leads to another device. Sidekick's HTTPS (pinned
  certificate) goes through untouched. Dart: `platform/apple_p2p.dart`;
  `AppState` (`_checkP2p`, `viaDirectWifi`, `clientFor`) uses it only when
  the device isn't on the same network (`_onLan`). Looking for devices
  costs Wi-Fi time, so on Wi-Fi it looks 10 s a minute while a paired
  iPhone/Mac is away, and stays on only while one is reached, while
  pairing (QR code: `_reachInviteDirect`), or with no Wi-Fi at all. The
  server never records 127.0.0.1 as a device's address (`_remoteAddress`).
  Both Info.plists list the service in `NSBonjourServices`.
- Pairing is SPAKE2 with either the 6-digit code or a QR invite's secret
  (`PairingInvite`: 5 minutes, one device, closed with the dialog). The
  scanner only talks to the address that presents the QR code's
  certificate fingerprint, and falls back to Bluetooth. Camera: iOS
  `NSCameraUsageDescription`; Android's permission comes from the plugin.
  The Mac has no camera permission (it never scans).
- **Shared clipboard** (`platform/clipboard.dart` `ClipboardWatcher`,
  `/v1/clipboard`, Settings → Share clipboard, on by default; text only, up
  to 256 KB): what's copied here goes to every paired device in reach (same
  network, Apple's link, or Bluetooth where allowed; never opens a network
  for it), and what they send lands in this clipboard ("Copied from …").
  Windows polls `GetClipboardSequenceNumber` (FFI), the Mac
  `NSPasteboard.changeCount` (`clipboardState`), Android listens
  (`sidekick/clipboard`, only while on screen: Android's rule). The iPhone
  never reads by itself (iOS asks "Allow Paste?"): the card's Clipboard
  button sends it (works on every platform). Never shared: Windows
  `ExcludeClipboardContentFromMonitorProcessing` / `Clipboard Viewer
  Ignore`, Mac `ConcealedType` / `TransientType`, Android 13
  `EXTRA_IS_SENSITIVE`. `_lastClip` stops echoes.
- **Live Activities** (iPhone, iOS 16.2+): a transfer's progress on the
  Lock Screen and in the Dynamic Island, for files coming in (once
  accepted) and going out with Send (`platform/live_activity.dart`
  `LiveTransfers`, at most one update a second; ends with Received / Sent /
  Declined…, gone 4 s later). Native: `LiveTransfers` in AppDelegate.swift
  (`liveStart`, `liveUpdate`, `liveEnd`); `Runner/TransferActivity.swift`
  (the attributes) is compiled into both the app and the **SidekickLive**
  widget extension (`ios/SidekickLive/`, its own target in the Xcode
  project, embedded by "Embed Foundation Extensions", which must stay
  before "Thin Binary"; bundle id `dev.sidekick.sidekick.LiveActivity`,
  which the TestFlight job renames along with the app's).
  `NSSupportsLiveActivities` is on in Info.plist. When adding objects to
  the .pbxproj by hand, use IDs nothing else has (2.7.0's first push reused
  the app icon's and Xcode called the project damaged).
- **Ping** (`/v1/ping`, the card's Ping button): the other device plays
  `ping.wav` three times (`tool/make_ping.py`; Android on the alarm volume,
  heard on silent; whatever Settings → Sound says) and shows "Ping from …"
  with Stop (`ui/ping.dart`); in the tray the window opens, a phone in the
  background gets a notification.
- Devices announce their release (`DeviceInfo.app`, "2.2.0"); a paired card
  shows "Update Sidekick on it" when the other device runs an older one.
- **iPhones can't be controlled** (Apple allows no app to): Remote on an
  iPhone shows only why (`_IphoneCantBeControlled`, no input session, no
  touchpad), iPhone device cards have no Remote shortcut, and a one-time
  pop-up says so the first time a device pairs with or picks an iPhone
  (`showIphoneRemoteNotice`, pref `iphoneRemoteNotice`).
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

### 2.10.0
- **Live Activities on iPhone:** a transfer's progress on the Lock Screen
  and in the Dynamic Island, receiving and sending: who, what, a progress
  bar and percentage, then Received / Sent (or Declined) for a few seconds.

### 2.9.0
- **Shared clipboard on every device:** copy on one, paste on the other.
  Windows, Mac and Android send what you copy by themselves (Android while
  Sidekick is open); on an iPhone tap Clipboard on the device card. What
  arrives goes straight into the clipboard. Passwords from password
  managers are never shared. Settings → Share clipboard turns it off.
- **Ping:** a Ping button on each device card makes the other device play
  a loud sound (heard even on silent on Android) and say who pinged, to
  find it or get someone's attention.

### 2.8.0
- **Direct Wi-Fi between any two devices, no router needed:** Android ↔
  Android, iPhone ↔ Android, iPhone ↔ Windows, Windows ↔ Mac, Windows ↔
  Windows and Android ↔ computers (iPhone ↔ Mac already had Apple's link).
  An Android phone opens a private network, or a Windows PC a Wi-Fi Direct
  one, and the other device joins it; files and Remote then go at Wi-Fi
  speed instead of over Bluetooth.
- **Works on different Wi-Fi networks too:** Bluetooth only finds the other
  device and hands over the network's name and password.
- **Find nearby:** a device that can't be reached offers to turn on
  Bluetooth to find it.
- **Pair with no Wi-Fi and no Bluetooth:** with no Wi-Fi, an Android phone
  or PC puts a private network in its QR code; the phone that scans it
  joins and pairs.
- iPhones join by themselves where the build allows it; otherwise they show
  the network's name and password to join in Settings → Wi-Fi.

### 2.7.1
- **Fixed: the Mac's red close button quit Sidekick** (2.6.6 and 2.7.0).
  Now it only hides the window: Sidekick keeps running in the menu bar and
  the Dock, still receiving (requests pop up in the corner), until Quit
  Sidekick in the menu bar (or ⌘Q).

### 2.7.0
- **Direct Wi-Fi between iPhones and Macs, no router needed:** iPhone ↔
  Mac, iPhone ↔ iPhone and Mac ↔ Mac find each other and send at Wi-Fi
  speed over Apple's peer-to-peer Wi-Fi (the link AirDrop uses), with no
  shared network and no Bluetooth. Pairing by QR code works over it too.
  The device card says "Connected via direct Wi-Fi".

### 2.6.6
- **The Mac keeps Sidekick in the menu bar:** the red close button no
  longer quits it. Sidekick stays in the Dock and the menu bar (Open,
  Quit), still receiving, and a request pops up the small corner window,
  like on Windows, without taking the focus.
- **A nicer, animated corner pop-up** on Windows and Mac: it rises into
  the corner, rings ripple from the sending device, a countdown runs along
  the top, Accept glows, a ring and bar fill while files arrive, a check
  pops in when they're all in, and it fades away.

### 2.6.5
- **Remote on an iPhone** no longer shows a touchpad that can't work: it
  says iPhones can't be controlled (Apple doesn't allow it) and to use the
  iPhone as the remote instead. A one-time pop-up explains it the first
  time a device pairs with or picks an iPhone; iPhone cards have no Remote
  shortcut.

### 2.6.4
- **Sharper app icons:** the shadow and edge highlight behind "sk" are gone
  (Mac, iPhone, the Liquid Glass icon, the website's tab and home-screen
  icons): they blurred the letters.

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

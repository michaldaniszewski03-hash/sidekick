import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/ble_protocol.dart';
import 'core/bluetooth.dart';
import 'core/client.dart';
import 'core/crypto.dart';
import 'core/discovery.dart';
import 'core/models.dart';
import 'core/server.dart';
import 'core/trust.dart';
import 'platform/android.dart';
import 'platform/device_name.dart';
import 'platform/files.dart';
import 'platform/ios.dart';
import 'platform/hotspot.dart';
import 'platform/macos.dart';
import 'platform/input.dart';
import 'platform/secret_store.dart';

/// The color themes in Settings → Theme: name and seed color.
const themeColors = <String, (String, Color)>{
  'purple': ('Sidekick purple', Color(0xFF6750A4)),
  'blue': ('Ocean', Color(0xFF1B6EF3)),
  'teal': ('Teal', Color(0xFF00897B)),
  'green': ('Forest', Color(0xFF2E7D32)),
  'orange': ('Sunset', Color(0xFFF57C00)),
  'red': ('Cherry', Color(0xFFD32F2F)),
  'pink': ('Blossom', Color(0xFFD81B60)),
  'mono': ('Monochrome', Color(0xFF757575)),
};

enum TransferState { running, done, failed }

class Transfer {
  Transfer({required this.name, required this.upload, required this.deviceName});

  final String name;
  final bool upload;
  final String deviceName;
  int done = 0;
  int total = 0;

  /// How it was protected in transit; set once it's done.
  TransferSecurity? security;

  /// The other device's certificate, for the security code.
  String? peerFingerprint;
  TransferState state = TransferState.running;
  String? error;
  String? localPath;

  /// Sent to us by the other device (not something we downloaded).
  bool received = false;

  double? get fraction => total > 0 ? done / total : null;
}

enum SendPhase { connecting, waiting, sending, done, declined, noAnswer, failed }

/// Files being sent with Send: asks the other device first, then uploads.
/// The full-screen sending view follows it.
class OutgoingSend extends ChangeNotifier {
  OutgoingSend({required this.device, required this.names, required this.total});
  final PairedDevice device;
  final List<String> names;
  final int total;

  SendPhase phase = SendPhase.connecting;
  int done = 0;

  /// Index of the file being sent (0-based).
  int current = 0;
  String? error;
  bool cancelled = false;
  Future<void> Function()? _cancelOffer;

  bool get finished => phase.index >= SendPhase.done.index;
  double get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : (phase == SendPhase.done ? 1 : 0);

  void _set(SendPhase p, {String? error}) {
    phase = p;
    this.error = error;
    notifyListeners();
  }

  void _progress(int bytes) {
    done = bytes;
    notifyListeners();
  }

  /// Stops waiting for an answer (the other device's prompt closes too).
  Future<void> cancel() async {
    if (phase != SendPhase.connecting && phase != SendPhase.waiting) return;
    cancelled = true;
    notifyListeners();
    try {
      await _cancelOffer?.call();
    } catch (_) {}
  }
}

class NearbyDevice {
  NearbyDevice(this.info) : lastSeen = DateTime.now();
  DeviceInfo info;
  DateTime lastSeen;
}

/// A one-off message for the snackbar.
class Notice {
  Notice(this.message, {this.revealPath});
  final String message;

  /// If set, the snackbar offers "Show in folder" for this file.
  final String? revealPath;
}

DevicePlatform get currentPlatform {
  if (Platform.isWindows) return DevicePlatform.windows;
  if (Platform.isMacOS) return DevicePlatform.macos;
  if (Platform.isLinux) return DevicePlatform.linux;
  if (Platform.isAndroid) return DevicePlatform.android;
  if (Platform.isIOS) return DevicePlatform.ios;
  return DevicePlatform.unknown;
}

/// All app state in one place. Screens listen to it with ListenableBuilder.
class AppState extends ChangeNotifier {
  AppState._(this._prefs);

  final SharedPreferences _prefs;

  late String id;
  late String name;
  ThemeMode themeMode = ThemeMode.system;

  /// Color theme: a [themeColors] key, or 'system' to follow the OS accent
  /// or wallpaper colors where there are any.
  String themeColor = 'system';

  /// True-black backgrounds in dark mode (saves battery on OLED screens).
  bool pureBlack = false;

  /// The first-launch welcome has been shown (it never shows again).
  bool welcomed = false;

  /// iPhone: keep running while other apps are open, so computers can still
  /// reach it (files, browsing).
  bool keepRunning = true;

  /// This build's version, e.g. "0.4.0" (shown in Settings → About).
  String appVersion = '';
  Permissions permissions = const Permissions();
  String? _receiveDir;

  final trust = TrustStore();
  final Map<String, PairedDevice> _paired = {};
  final Map<String, NearbyDevice> _nearby = {};
  final Map<String, DateTime> _lastContact = {};
  final List<Transfer> transfers = [];
  final Map<String, TrustedPeer> activeRemoteSessions = {};
  List<String> addresses = [];
  String? selectedId;
  String? networkError;

  late final InputInjector input = InputInjector.forCurrentPlatform();
  late final FileService files;
  late final SidekickServer server;

  /// This device's certificate: its identity for encrypted connections.
  late final Identity identity;

  /// Where pairing tokens, pairing keys and our private key live.
  late final SecretStore secrets;
  bool _droppedOldPairings = false;

  /// What each device we're pairing with showed us in the pairing request.
  final Map<String, PairingTarget> _pairTargets = {};
  late final Discovery discovery;

  /// Bluetooth, for when devices don't share a Wi-Fi network. Null on
  /// platforms without support (and in tests).
  BluetoothService? bluetooth;
  final Map<String, BleSighting> _bleSeen = {};
  final Map<String, PeerClient> _bleClients = {};
  Timer? _bleTimer;

  /// AirDrop-style direct Wi-Fi: Bluetooth hands over a hotspot's name and
  /// password, then everything runs over Wi-Fi.
  final directLink = DirectLink.forCurrentPlatform();
  final Map<String, Future<bool>> _directConnecting = {};
  final Map<String, Timer> _directIdle = {};

  /// Devices we're setting up a direct link with right now.
  Set<String> get connectingDirect => _directConnecting.keys.toSet();

  final _pairRequests = StreamController<PairingRequest>.broadcast();
  final _offers = StreamController<TransferOffer>.broadcast();
  final _sends = StreamController<OutgoingSend>.broadcast();

  /// Another device wants to send files here: ask the user.
  Stream<TransferOffer> get transferOffers => _offers.stream;

  /// A Send started here: show it full screen.
  Stream<OutgoingSend> get sends => _sends.stream;

  /// Ask before accepting files sent to this device (Settings → Files).
  bool askBeforeReceiving = true;

  /// Play the startup chime when Sidekick opens.
  bool startupSound = true;
  final _pairedEvents = StreamController<PairedDevice>.broadcast();
  final _notices = StreamController<Notice>.broadcast();

  /// Someone wants to pair with us: show the PIN.
  Stream<PairingRequest> get pairRequests => _pairRequests.stream;

  /// A pairing finished (either direction).
  Stream<PairedDevice> get pairedEvents => _pairedEvents.stream;
  Stream<Notice> get notices => _notices.stream;

  Timer? _presenceTimer;
  Timer? _scanTimer;
  Timer? _permissionTimer;

  static Future<AppState> load() async {
    final state = AppState._(await SharedPreferences.getInstance());
    state._restore();
    await state._loadSecrets();
    // Use the device's real name unless the user picked one (older versions
    // saved made-up names like "My ios"; replace those too).
    final saved = state._prefs.getString('name');
    if (saved == null || isLegacyDefaultName(saved)) {
      try {
        state.name = await detectDeviceName();
      } catch (_) {
        state.name = _defaultName();
      }
      await state._prefs.setString('name', state.name);
    }
    return state;
  }

  // ---------------------------------------------------------------- persistence

  void _restore() {
    id = _prefs.getString('id') ?? newDeviceId();
    _prefs.setString('id', id);
    name = _prefs.getString('name') ?? _defaultName();
    themeMode = ThemeMode.values.asNameMap()[_prefs.getString('themeMode')] ?? ThemeMode.system;
    themeColor = _prefs.getString('themeColor') ?? (Platform.isIOS ? 'purple' : 'system');
    if (themeColor != 'system' && !themeColors.containsKey(themeColor)) themeColor = 'system';
    pureBlack = _prefs.getBool('pureBlack') ?? false;
    keepRunning = _prefs.getBool('keepRunning') ?? true;
    askBeforeReceiving = _prefs.getBool('askBeforeReceiving') ?? true;
    startupSound = _prefs.getBool('startupSound') ?? true;
    welcomed = _prefs.getBool('welcomed') ?? false;
    permissions = Permissions(files: _prefs.getBool('allowFiles') ?? true, input: _prefs.getBool('allowInput') ?? true);
    _receiveDir = _prefs.getString('receiveDir');
    selectedId = _prefs.getString('selectedId');
  }

  /// Loads pairings and this device's identity from secure storage (moving
  /// them there from app settings, where versions before 0.5 kept them).
  Future<void> _loadSecrets() async {
    // On a Mac, a file only this user can read: the keychain would keep
    // asking for the password, since the app isn't signed by a paid account.
    secrets = SecretStore(
      _prefs,
      file: Platform.isMacOS ? File(p.join((await getApplicationSupportDirectory()).path, 'secrets.json')) : null,
    );
    List<String> list(String? json) => json == null ? const [] : [for (final e in jsonDecode(json) as List) '$e'];
    String? legacyList(String key) {
      final old = _prefs.getStringList(key);
      return old == null ? null : jsonEncode(old);
    }

    final trusted = await secrets.read(
      'trusted',
      legacy: () => legacyList('trusted'),
      removeLegacy: () => _prefs.remove('trusted'),
    );
    final paired = await secrets.read(
      'paired',
      legacy: () => legacyList('paired'),
      removeLegacy: () => _prefs.remove('paired'),
    );
    // Pairings from before encryption (no certificate or key) can't be
    // trusted any more; the user pairs those devices again.
    for (final json in list(trusted)) {
      try {
        trust.add(TrustedPeer.fromJson(jsonDecode(json) as Map<String, dynamic>));
      } on TypeError {
        _droppedOldPairings = true;
      }
    }
    for (final json in list(paired)) {
      try {
        final d = PairedDevice.fromJson(jsonDecode(json) as Map<String, dynamic>);
        _paired[d.id] = d;
      } on TypeError {
        _droppedOldPairings = true;
      }
    }
    trust.onChanged = _saveTrusted;
    if (_droppedOldPairings) {
      _saveTrusted();
      _savePaired();
    }
    identity = await _loadIdentity();
    await secrets.finishedMoving();
  }

  void _saveTrusted() => unawaited(secrets.write('trusted', jsonEncode([for (final t in trust.peers) jsonEncode(t)])));

  void _savePaired() => unawaited(secrets.write('paired', jsonEncode([for (final d in _paired.values) jsonEncode(d)])));

  static String _defaultName() {
    final host = Platform.localHostname;
    if (host.isEmpty || host == 'localhost') return 'My ${currentPlatform.name}';
    return host.split('.').first;
  }

  // ---------------------------------------------------------------- lifecycle

  DeviceInfo get me => DeviceInfo(
    id: id,
    name: name,
    platform: currentPlatform,
    port: server.port == 0 ? sidekickPort : server.port,
    fingerprint: identity.fingerprint,
    app: appVersion.isEmpty ? null : appVersion,
    capabilities: Capabilities(
      files: permissions.files && (!Platform.isAndroid || AndroidBridge.permissions.allFiles),
      input: permissions.input && input.supported,
    ),
  );

  Future<void> start() async {
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        await AndroidBridge.acquireMulticastLock();
        await AndroidBridge.refresh();
      } catch (_) {
        // Discovery may be flaky, but Add by IP still works.
      }
    }
    if (Platform.isMacOS) {
      try {
        await MacBridge.refresh();
      } catch (_) {}
    }
    if (Platform.isIOS) unawaited(setIosKeepAlive(keepRunning));
    // iOS apps can only share their own Documents folder.
    files = Platform.isIOS ? FileService(home: (await getApplicationDocumentsDirectory()).path) : FileService();
    server = SidekickServer(
      identity: identity,
      self: () => me,
      trust: trust,
      files: files,
      input: input,
      receiveDir: receiveDir,
      permissions: () => permissions,
      link: directLink,
      inputReady: _inputReady,
      askBeforeReceiving: () => askBeforeReceiving,
    );
    server.events.listen(_onServerEvent);
    await _startServer();

    discovery = Discovery(self: () => me);
    discovery.found.listen(_onFound);
    try {
      await discovery.start();
    } catch (e) {
      // iOS needs a special Apple entitlement for multicast; the scan below
      // covers it. Elsewhere, say why devices may not show up.
      if (!Platform.isIOS) {
        networkError ??= "Couldn't search the network ($e). Use Scan network or Add by IP.";
      }
    }
    if (Platform.isIOS) {
      unawaited(scanNetwork());
      _scanTimer = Timer.periodic(const Duration(seconds: 30), (_) => scanNetwork());
    }

    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows) {
      final bt = bluetooth = BluetoothService(self: () => me, server: server)..onChanged = _bluetoothChanged;
      bt.found.listen(_onBluetoothSighting);
      bt.statusChanges.listen((_) => notifyListeners());
      unawaited(bt.start().then((_) => _maybeScanBluetooth()).catchError((_) {}));
      _bleTimer = Timer.periodic(const Duration(seconds: 10), (_) => _maybeScanBluetooth());
    }

    if (Platform.isMacOS) {
      // Coming back from System Settings doesn't always count as "resumed".
      _permissionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!MacBridge.accessibility) unawaited(_inputReady());
      });
    }

    if (_droppedOldPairings) {
      _notices.add(Notice('Sidekick now encrypts everything. Pair your devices again to keep using them.'));
    }

    addresses = await localAddresses();
    _presenceTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkPresence());
    unawaited(_checkPresence());
    notifyListeners();
  }

  Future<Identity> _loadIdentity() async {
    final saved = await secrets.read(
      'identity',
      legacy: () => _prefs.getString('identity'),
      removeLegacy: () => _prefs.remove('identity'),
    );
    if (saved != null) {
      try {
        return Identity.fromJson(jsonDecode(saved) as Map<String, dynamic>);
      } catch (_) {
        // Corrupt: make a new one (paired devices will ask to pair again).
      }
    }
    // Key generation takes a moment; keep the UI responsive.
    final fresh = await Isolate.run(Identity.generate);
    await secrets.write('identity', jsonEncode(fresh.toJson()));
    return fresh;
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _scanTimer?.cancel();
    _permissionTimer?.cancel();
    _bleTimer?.cancel();
    _bluetoothRedraw?.cancel();
    for (final t in _directIdle.values) {
      t.cancel();
    }
    directLink.stopHosting();
    directLink.leave();
    bluetooth?.stop();
    discovery.stop();
    server.stop();
    super.dispose();
  }

  /// Re-reads things the user may have changed in system settings while we
  /// were in the background (Android permissions).
  Future<void> refreshPlatform() async {
    try {
      if (Platform.isAndroid) {
        await AndroidBridge.refresh();
      } else if (Platform.isMacOS) {
        await MacBridge.refresh();
      } else {
        return;
      }
    } catch (_) {
      return;
    }
    discovery.announce();
    notifyListeners();
  }

  /// Re-checks the OS permission for remote input, so granting it works
  /// right away (and so peers learn about it).
  Future<bool> _inputReady() async {
    final before = input.supported;
    try {
      if (Platform.isMacOS) await MacBridge.refresh();
      if (Platform.isAndroid) await AndroidBridge.refresh();
    } catch (_) {}
    if (input.supported != before) {
      discovery.announce();
      notifyListeners();
    }
    return input.supported;
  }

  bool scanning = false;

  /// Asks every address on this device's /24 networks for `/v1/info`. Finds
  /// devices where multicast discovery doesn't work (iOS, some routers).
  Future<void> scanNetwork() async {
    if (scanning) return;
    scanning = true;
    notifyListeners();
    // Look over Bluetooth at the same time.
    final bluetoothScan = bluetooth?.scan() ?? Future<void>.value();
    try {
      final queue = <String>[];
      for (final address in await localAddresses()) {
        final parts = address.split('.');
        if (parts.length != 4 || !_isPrivate(address)) continue;
        for (var i = 1; i < 255; i++) {
          final host = '${parts[0]}.${parts[1]}.${parts[2]}.$i';
          if (host != address) queue.add(host);
        }
      }
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          final host = queue.removeLast();
          try {
            final info = await PeerClient(host: host).info(timeout: const Duration(milliseconds: 800));
            if (info.id != id) _onFound(info);
          } catch (_) {
            // Nothing there, or not Sidekick.
          }
        }
      }

      await Future.wait([...List.generate(32, (_) => worker()), bluetoothScan]);
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  static bool _isPrivate(String a) =>
      a.startsWith('10.') || a.startsWith('192.168.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a);

  // ---------------------------------------------------------------- devices

  List<PairedDevice> get paired => _paired.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  /// Devices we've heard from recently that we haven't paired with. Ones
  /// seen only over Bluetooth have no [DeviceInfo.address].
  List<DeviceInfo> get nearby {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 20));
    final wifi = {
      for (final n in _nearby.values)
        if (n.lastSeen.isAfter(cutoff) && !_paired.containsKey(n.info.id)) n.info.id: n.info,
    };
    final bleCutoff = DateTime.now().subtract(const Duration(seconds: 60));
    return [
      ...wifi.values,
      for (final s in _bleSeen.values)
        if (s.seen.isAfter(bleCutoff) && !_paired.containsKey(s.info.id) && !wifi.containsKey(s.info.id)) s.info,
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  PairedDevice? pairedById(String? id) => id == null ? null : _paired[id];

  /// [d] now presents a different certificate than it paired with (it was
  /// reset or reinstalled), so it has to be paired again.
  DeviceInfo? needsRepair(PairedDevice d) {
    final seen = _nearby[d.id]?.info ?? _bleSeen[d.id]?.info;
    final fp = seen?.fingerprint;
    if (fp != null && fp != d.fingerprint) return seen;
    // Found out the hard way: a connection was refused for a new certificate.
    if (_identityChanged.contains(d.id)) {
      return seen ?? DeviceInfo(id: d.id, name: d.name, platform: d.platform, port: d.lastPort, address: d.lastAddress);
    }
    return null;
  }

  final Set<String> _identityChanged = {};

  /// The Sidekick release [d] runs, if it says (2.1.3 and later do).
  String? appVersionOf(PairedDevice d) => (_nearby[d.id]?.info ?? _bleSeen[d.id]?.info)?.app;

  /// [d] runs an older Sidekick than this device (or one too old to say
  /// which): the two may not understand each other fully until it updates.
  bool runsOlderApp(PairedDevice d) {
    final seen = _nearby[d.id]?.info ?? _bleSeen[d.id]?.info;
    if (seen == null || appVersion.isEmpty) return false;
    final theirs = seen.app;
    return theirs == null || compareVersions(theirs, appVersion) < 0;
  }

  /// Adds "update it" to an error when [d] runs an older Sidekick.
  String _withUpdateHint(PairedDevice d, Object error) => runsOlderApp(d)
      ? '$error\n${d.name} runs an older Sidekick${appVersionOf(d) == null ? '' : ' (${appVersionOf(d)})'}: '
            'update it to $appVersion.'
      : '$error';

  /// Remembers a device whose certificate changed, so it shows "Pair again".
  void _noteFailure(PairedDevice d, Object error) {
    if (error is SidekickException && error.identityChanged && _identityChanged.add(d.id)) notifyListeners();
  }

  /// Forgets [d] here (it no longer knows us anyway) so it can be paired
  /// again; returns how to reach it.
  DeviceInfo forgetForRepair(PairedDevice d) {
    final seen = needsRepair(d)!;
    _paired.remove(d.id);
    trust.remove(d.id);
    _identityChanged.remove(d.id);
    _savePaired();
    notifyListeners();
    return seen;
  }

  /// The code to compare with the one [d] shows for us (Settings → Paired
  /// devices), proving the connection is between these two devices only.
  String securityCodeFor(PairedDevice d) => securityCode(identity.fingerprint, d.fingerprint);

  /// Capabilities the device last announced, if we've seen it.
  Capabilities? capabilitiesOf(String id) => _nearby[id]?.info.capabilities ?? _bleSeen[id]?.info.capabilities;

  /// Reachable over the local network (fast, all features).
  bool reachableViaWifi(String id) {
    final t = _lastContact[id];
    return t != null && DateTime.now().difference(t) < const Duration(seconds: 25);
  }

  /// Seen over Bluetooth in the last minute.
  bool reachableViaBluetooth(String id) {
    final s = _bleSeen[id];
    return s != null && DateTime.now().difference(s.seen) < const Duration(seconds: 60);
  }

  /// Wi-Fi isn't available for this device but Bluetooth is, so requests go
  /// over Bluetooth (slower, no remote control).
  bool viaBluetooth(String id) => !reachableViaWifi(id) && reachableViaBluetooth(id);

  bool isOnline(String id) => reachableViaWifi(id) || reachableViaBluetooth(id);

  PairedDevice? get selected {
    final d = pairedById(selectedId);
    if (d != null) return d;
    final list = paired;
    return list.isEmpty ? null : list.firstWhere((d) => isOnline(d.id), orElse: () => list.first);
  }

  void select(String id) {
    selectedId = id;
    _prefs.setString('selectedId', id);
    notifyListeners();
  }

  /// Wi-Fi when the device is reachable there; otherwise Bluetooth if it's
  /// nearby; otherwise Wi-Fi again (which fails with a helpful message).
  PeerClient clientFor(PairedDevice d) {
    final sighting = _bleSeen[d.id];
    final bt = bluetooth;
    if (reachableViaWifi(d.id) || sighting == null || bt == null || !reachableViaBluetooth(d.id)) {
      return PeerClient.forDevice(d);
    }
    // Paired again since (new key or token): the cached client would seal
    // with the old key, and the other device would refuse everything.
    final cached = _bleClients[d.id];
    if (cached != null && cached.token == d.token && base64.encode(cached.seal!.key) == d.key) return cached;
    return _bleClients[d.id] = PeerClient.bluetooth(
      bt.clientFor(sighting.bleId),
      token: d.token,
      seal: BleSeal(senderId: id, key: base64.decode(d.key)),
    );
  }

  PeerClient _clientForTarget(DeviceInfo target) {
    final address = target.address;
    if (address != null) return PeerClient(host: address, port: target.port);
    final sighting = _bleSeen[target.id];
    final bt = bluetooth;
    if (sighting == null || bt == null) throw SidekickException('${target.name} is out of reach.');
    return PeerClient.bluetooth(bt.clientFor(sighting.bleId));
  }

  /// Whether this device and [d] can set up a direct Wi-Fi link: an
  /// Android phone opens a hotspot, a Windows PC or Mac joins it.
  bool canConnectDirect(PairedDevice d) {
    final peerHosts = d.platform == DevicePlatform.android;
    final peerJoins = d.platform == DevicePlatform.windows || d.platform == DevicePlatform.macos;
    return (directLink.canHost && peerJoins) || (directLink.canJoin && peerHosts);
  }

  /// Makes [d] reachable over Wi-Fi if it's only nearby over Bluetooth, by
  /// setting up a direct link. True when Wi-Fi works afterwards.
  Future<bool> connectDirect(PairedDevice d) {
    if (reachableViaWifi(d.id)) {
      _keepDirect(d);
      return Future.value(true);
    }
    if (!viaBluetooth(d.id) || !canConnectDirect(d)) return Future.value(false);
    final pending = _directConnecting[d.id];
    if (pending != null) return pending;
    final attempt = _directConnecting[d.id] = _connectDirect(d);
    notifyListeners();
    return attempt.whenComplete(() {
      _directConnecting.remove(d.id);
      notifyListeners();
    });
  }

  Future<bool> _connectDirect(PairedDevice d) async {
    final ble = clientFor(d);
    final port = _bleSeen[d.id]?.info.port ?? d.lastPort;
    List<String> candidates;
    try {
      if (directLink.canHost) {
        final creds = await directLink.host();
        candidates = await ble.joinHotspot(creds);
      } else {
        final creds = await ble.startHotspot();
        await directLink.join(creds);
        candidates = creds.addresses;
      }
    } catch (e) {
      await _releaseDirect(d, ble);
      _notices.add(Notice("Couldn't set up a direct Wi-Fi link: $e"));
      return false;
    }
    // Give both sides a moment to finish getting on the network.
    for (var attempt = 0; attempt < 8; attempt++) {
      for (final host in candidates) {
        try {
          final info = await PeerClient(host: host, port: port).info(timeout: const Duration(seconds: 2));
          if (info.id == d.id) {
            _onFound(info);
            _keepDirect(d);
            return true;
          }
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await _releaseDirect(d, ble);
    _notices.add(Notice("Joined ${d.name}'s hotspot but couldn't reach it. Check the firewall."));
    return false;
  }

  /// Keeps a direct link while it's in use; closes it after a quiet spell.
  void _keepDirect(PairedDevice d) {
    final timer = _directIdle[d.id];
    if (timer == null && !_directConnecting.containsKey(d.id)) return; // Not a direct link.
    timer?.cancel();
    _directIdle[d.id] = Timer(const Duration(minutes: 3), () {
      if (transfers.any((t) => t.state == TransferState.running && t.deviceName == d.name) ||
          activeRemoteSessions.isNotEmpty) {
        _keepDirect(d);
      } else {
        unawaited(_releaseDirect(d, PeerClient.forDevice(d)));
      }
    });
  }

  Future<void> _releaseDirect(PairedDevice d, PeerClient peer) async {
    _directIdle.remove(d.id)?.cancel();
    try {
      await peer.releaseLink();
    } catch (_) {}
    await directLink.stopHosting();
    await directLink.leave();
    _lastContact.remove(d.id);
    notifyListeners();
  }

  /// Before a big transfer or remote control over Bluetooth, try to switch
  /// to a direct Wi-Fi link. Small things just go over Bluetooth.
  Future<PeerClient> _clientForTransfer(PairedDevice d, int bytes) async {
    if (viaBluetooth(d.id) && bytes > directLinkThreshold) await connectDirect(d);
    if (_directIdle.containsKey(d.id)) _keepDirect(d);
    return clientFor(d);
  }

  /// Bigger transfers than this set up a direct Wi-Fi link when they'd
  /// otherwise crawl over Bluetooth.
  static const directLinkThreshold = 2 * 1024 * 1024;

  // Bluetooth can report dozens of advertisements a second; redraw at most
  // four times a second so the app stays responsive.
  Timer? _bluetoothRedraw;
  void _bluetoothChanged() {
    _bluetoothRedraw ??= Timer(const Duration(milliseconds: 250), () {
      _bluetoothRedraw = null;
      notifyListeners();
    });
  }

  /// Devices seen over Bluetooth recently, for Settings → Bluetooth.
  List<BleSighting> get bluetoothSightings => _bleSeen.values.toList()..sort((a, b) => b.seen.compareTo(a.seen));

  /// Scans now, even if Wi-Fi reaches everything (Settings → Scan now).
  Future<void> scanBluetoothNow() async => bluetooth?.scan();

  void _onBluetoothSighting(BleSighting sighting) {
    final id = sighting.info.id;
    final previous = _bleSeen[id];
    _bleSeen[id] = sighting;
    // A new Bluetooth address (phone restarted Bluetooth) needs a new link.
    if (previous != null && previous.bleId != sighting.bleId) _bleClients.remove(id);
    notifyListeners();
  }

  /// Bluetooth is only for when Wi-Fi can't do the job: this device has no
  /// network, a paired device isn't reachable over it, or nothing's nearby.
  Future<void> _maybeScanBluetooth() async {
    final bt = bluetooth;
    if (bt == null) return;
    await bt.refresh();
    if (!bt.canScan) return;
    // No Wi-Fi at all (a field, a train): Bluetooth is the only way, so look
    // every 10 s. On Wi-Fi, only every 20 s and only for devices it can't reach.
    final offline = addresses.isEmpty;
    _bleTick++;
    if (!offline && _bleTick.isOdd) return;
    final needed = offline || _paired.keys.any((id) => !reachableViaWifi(id)) || (_paired.isEmpty && nearby.isEmpty);
    if (needed) await bt.scan();
  }

  int _bleTick = 0;

  void _onFound(DeviceInfo info) {
    final existing = _nearby[info.id];
    final isNew = existing == null || existing.info.address != info.address || existing.info.name != info.name;
    if (existing == null) {
      _nearby[info.id] = NearbyDevice(info);
    } else {
      existing
        ..info = info
        ..lastSeen = DateTime.now();
    }
    _lastContact[info.id] = DateTime.now();
    final pairedDevice = _paired[info.id];
    if (pairedDevice != null &&
        (pairedDevice.lastAddress != info.address ||
            pairedDevice.lastPort != info.port ||
            pairedDevice.name != info.name)) {
      pairedDevice
        ..lastAddress = info.address
        ..lastPort = info.port
        ..name = info.name;
      _savePaired();
    }
    if (isNew || pairedDevice != null) notifyListeners();
  }

  /// Pings paired devices we haven't heard from over multicast, in case the
  /// network blocks it.
  /// Starts the server on Sidekick's port, or any free one if it's taken
  /// (another copy running?); discovery announces the real one.
  Future<void> _startServer({int port = sidekickPort}) async {
    try {
      await server.start(port: port);
    } catch (_) {
      try {
        await server.start(port: 0);
      } catch (e) {
        networkError = "Couldn't start the Sidekick server: $e";
      }
    }
  }

  bool _healing = false;

  /// Back in the foreground. Phones may have closed a backgrounded app's
  /// sockets, so check the server still answers (restart it if not) and
  /// rejoin the network; everywhere, pick up permission changes.
  Future<void> resumed() async {
    if ((Platform.isIOS || Platform.isAndroid) && !_healing) {
      _healing = true;
      try {
        final port = server.port;
        var alive = port != 0;
        if (alive) {
          try {
            final probe = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
            probe.destroy();
          } catch (_) {
            alive = false;
          }
        }
        if (!alive) {
          await server.stop();
          await _startServer(port: port == 0 ? sidekickPort : port);
        }
        await _restartDiscovery();
        unawaited(_checkPresence());
      } finally {
        _healing = false;
      }
    }
    await refreshPlatform();
  }

  Future<void> _restartDiscovery() async {
    try {
      await discovery.start();
    } catch (_) {
      // No network right now; the next address change tries again.
    }
  }

  Future<void> _checkPresence() async {
    // A new network (Wi-Fi switch, wake from sleep): rejoin discovery on it
    // and show the new address.
    final now = await localAddresses();
    if (now.join(',') != addresses.join(',')) {
      addresses = now;
      unawaited(_restartDiscovery());
    }
    await Future.wait([
      for (final d in _paired.values)
        if (!reachableViaWifi(d.id) && d.lastAddress != null)
          PeerClient(host: d.lastAddress!, port: d.lastPort)
              .info(timeout: const Duration(seconds: 2))
              .then((info) {
                if (info.id == d.id) _onFound(info);
              })
              .catchError((_) {}),
    ]);
    // Also refreshes online dots and drops stale nearby devices.
    notifyListeners();
  }

  /// Adds a device by IP, for networks where discovery doesn't work.
  Future<DeviceInfo> addByAddress(String input) async {
    final parts = input.trim().split(':');
    final host = parts.first;
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? sidekickPort : sidekickPort;
    final info = await PeerClient(host: host, port: port).info();
    _onFound(info);
    return info;
  }

  // ---------------------------------------------------------------- pairing

  Future<void> requestPairing(DeviceInfo target) async {
    if (target.version < protocolVersion) {
      throw SidekickException('Update Sidekick on ${target.name} to pair with it (it needs version 0.3 or newer).');
    }
    _pairTargets[target.id] = await _clientForTarget(target).requestPairing(me, myFingerprint: identity.fingerprint);
  }

  Future<PairedDevice> confirmPairing(DeviceInfo target, String pin) async {
    final pairing = _pairTargets[target.id];
    if (pairing == null) throw SidekickException('Start pairing again.');
    final result = await _clientForTarget(target)
        .confirmPairing(myId: id, myFingerprint: identity.fingerprint, target: pairing, pin: pin);
    _pairTargets.remove(target.id);
    trust.add(
      TrustedPeer(
        id: result.device.id,
        name: result.device.name,
        platform: result.device.platform,
        token: result.tokenForThem,
        fingerprint: result.device.fingerprint,
        key: result.key,
      ),
    );
    _addPaired(result.device);
    return result.device;
  }

  void _addPaired(PairedDevice d) {
    _paired[d.id] = d;
    // Paired over Bluetooth there's no IP yet; Wi-Fi discovery fills it in.
    if (d.lastAddress != null) _lastContact[d.id] = DateTime.now();
    selectedId ??= d.id;
    _savePaired();
    _pairedEvents.add(d);
    notifyListeners();
  }

  Future<void> unpair(String deviceId) async {
    final d = _paired[deviceId];
    if (d != null) {
      try {
        await clientFor(d).unpair();
      } catch (_) {
        // Offline: they'll get 401s and can remove us themselves.
      }
    }
    _paired.remove(deviceId);
    trust.remove(deviceId);
    _savePaired();
    notifyListeners();
  }

  void cancelPairing(String deviceId) => server.cancelPairing(deviceId);

  // ---------------------------------------------------------------- server events

  void _onServerEvent(ServerEvent event) {
    switch (event) {
      case PairRequested(:final request):
        _pairRequests.add(request);
      case TransferOffered(:final offer):
        _offers.add(offer);
      case Paired(:final device):
        _addPaired(device);
        _notices.add(Notice('Paired with ${device.name}'));
      case Unpaired(:final peerId):
        final name = _paired.remove(peerId)?.name;
        _savePaired();
        notifyListeners();
        if (name != null) _notices.add(Notice('$name unpaired from this device'));
      case FileReceived(:final from, :final file, :final size, :final security):
        transfers.insert(
          0,
          Transfer(name: p.basename(file.path), upload: false, deviceName: from.name)
            ..done = size
            ..total = size
            ..state = TransferState.done
            ..received = true
            ..security = security
            ..peerFingerprint = from.fingerprint
            ..localPath = file.path,
        );
        if (transfers.length > 50) transfers.removeLast();
        notifyListeners();
        _notices.add(Notice('Received ${p.basename(file.path)} from ${from.name}', revealPath: file.path));
      case InputBlocked(:final peer):
        final where = Platform.isMacOS
            ? 'Allow Sidekick in Settings → Accessibility (if it\'s already on there, remove it and add it again).'
            : 'Allow remote control in Settings.';
        _notices.add(Notice('${peer.name} tried to control this device. $where'));
      case RemoteSessionChanged(:final peer, :final active):
        if (active) {
          activeRemoteSessions[peer.id] = peer;
        } else {
          activeRemoteSessions.remove(peer.id);
        }
        notifyListeners();
    }
  }

  // ---------------------------------------------------------------- transfers

  Future<String> receiveDir() async {
    if (_receiveDir != null) return _receiveDir!;
    // Shows up in the Files app under On My iPhone → Sidekick.
    if (Platform.isIOS) return (await getApplicationDocumentsDirectory()).path;
    if (Platform.isAndroid) {
      // The public Download folder needs "All files access"; otherwise use
      // Sidekick's own folder under Android/data.
      if (AndroidBridge.permissions.allFiles) return '/storage/emulated/0/Download/Sidekick';
      final own = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      return p.join(own.path, 'Sidekick');
    }
    Directory? downloads;
    try {
      downloads = await getDownloadsDirectory();
    } catch (_) {}
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return p.join(downloads?.path ?? p.join(home, 'Downloads'), 'Sidekick');
  }

  Transfer _startTransfer(String name, PairedDevice d, {required bool upload}) {
    final t = Transfer(name: name, upload: upload, deviceName: d.name)..peerFingerprint = d.fingerprint;
    transfers.insert(0, t);
    if (transfers.length > 50) transfers.removeLast();
    notifyListeners();
    return t;
  }

  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);
  void _progress(Transfer t, int done, int total) {
    t
      ..done = done
      ..total = total;
    final now = DateTime.now();
    if (now.difference(_lastProgressNotify) > const Duration(milliseconds: 100)) {
      _lastProgressNotify = now;
      notifyListeners();
    }
  }

  /// Sends local files to [d]. With [remoteDir] they go into that folder on
  /// the other device (it's browsing-level access, so nobody is asked);
  /// otherwise the other device is asked to accept them first, and they land
  /// in its receive folder.
  Future<void> sendFiles(PairedDevice d, List<File> localFiles, {String? remoteDir}) async {
    if (localFiles.isEmpty) return;
    final sizes = <int>[];
    for (final file in localFiles) {
      try {
        sizes.add(await file.length());
      } catch (_) {
        sizes.add(0);
      }
    }
    final total = sizes.fold(0, (a, b) => a + b);
    final names = [for (final f in localFiles) p.basename(f.path)];
    final what = localFiles.length == 1 ? names.first : '${localFiles.length} files';
    if (remoteDir != null) {
      _notices.add(Notice('Sending $what to ${d.name}…'));
    }
    final send = OutgoingSend(device: d, names: names, total: total);
    if (remoteDir == null) _sends.add(send);

    final PeerClient client;
    String? ticket;
    try {
      client = await _clientForTransfer(d, total);
      if (remoteDir == null) {
        if (send.cancelled) return;
        send._set(SendPhase.waiting);
        final offerId = newToken().substring(0, 16);
        send._cancelOffer = () => client.cancelOffer(offerId);
        final reply = await client.offerFiles(offerId, [for (var i = 0; i < names.length; i++) (names[i], sizes[i])]);
        if (send.cancelled || reply.answer == 'cancelled') {
          send._set(SendPhase.failed, error: 'Cancelled');
          return;
        }
        if (!reply.accepted) {
          final declined = reply.answer == 'declined';
          send._set(declined ? SendPhase.declined : SendPhase.noAnswer);
          _notices.add(Notice(declined ? '${d.name} declined $what' : 'No answer from ${d.name}. Nothing was sent.'));
          return;
        }
        ticket = reply.ticket;
        send._set(SendPhase.sending);
      }
    } catch (e) {
      _noteFailure(d, e);
      send._set(SendPhase.failed, error: _withUpdateHint(d, e));
      _notices.add(Notice("Couldn't send to ${d.name}: ${_withUpdateHint(d, e)}"));
      return;
    }

    var sent = 0;
    var before = 0;
    Object? failure;
    for (var i = 0; i < localFiles.length; i++) {
      final file = localFiles[i];
      final t = _startTransfer(names[i], d, upload: true);
      send
        ..current = i
        .._progress(before);
      try {
        await client.upload(
          file,
          name: names[i],
          remoteDir: remoteDir,
          ticket: ticket,
          onProgress: (a, b) {
            _progress(t, a, b);
            send._progress(before + a);
          },
        );
        t
          ..state = TransferState.done
          ..security = client.lastSecurity;
        sent++;
      } catch (e) {
        failure ??= e;
        _noteFailure(d, e);
        t
          ..state = TransferState.failed
          ..error = '$e';
      }
      before += sizes[i];
      send._progress(before);
      notifyListeners();
    }
    if (failure == null) {
      send._set(SendPhase.done);
    } else {
      final why = _withUpdateHint(d, failure);
      send._set(SendPhase.failed, error: sent == 0 ? why : 'Sent $sent of ${localFiles.length}. $why');
    }
    // Say how it went where the user is, not only in the Files tab.
    _notices.add(
      Notice(
        failure == null
            ? 'Sent $what to ${d.name}'
            : sent == 0
            ? "Couldn't send to ${d.name}: $failure"
            : 'Sent $sent of ${localFiles.length} files to ${d.name}. $failure',
      ),
    );
  }

  Future<File?> download(PairedDevice d, RemoteEntry entry) async {
    final t = _startTransfer(entry.name, d, upload: false);
    try {
      final dir = await receiveDir();
      await Directory(dir).create(recursive: true);
      final dest = await uniqueFile(dir, sanitizeFileName(entry.name));
      final client = await _clientForTransfer(d, entry.size);
      final file = await client.download(entry.path, dest, onProgress: (a, b) => _progress(t, a, b));
      t
        ..state = TransferState.done
        ..security = client.lastSecurity
        ..localPath = file.path;
      notifyListeners();
      _notices.add(Notice('Saved ${entry.name}', revealPath: file.path));
      return file;
    } catch (e) {
      _noteFailure(d, e);
      t
        ..state = TransferState.failed
        ..error = '$e';
      notifyListeners();
      return null;
    }
  }

  void clearFinishedTransfers() {
    transfers.removeWhere((t) => t.state != TransferState.running);
    notifyListeners();
  }

  // ---------------------------------------------------------------- settings

  void setName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    name = trimmed.length > 40 ? trimmed.substring(0, 40) : trimmed;
    _prefs.setString('name', name);
    discovery.announce();
    notifyListeners();
  }

  void setThemeColor(String color) {
    themeColor = color;
    _prefs.setString('themeColor', color);
    notifyListeners();
  }

  void finishWelcome() {
    welcomed = true;
    _prefs.setBool('welcomed', true);
    notifyListeners();
  }

  void setAskBeforeReceiving(bool value) {
    askBeforeReceiving = value;
    _prefs.setBool('askBeforeReceiving', value);
    notifyListeners();
  }

  void setStartupSound(bool value) {
    startupSound = value;
    _prefs.setBool('startupSound', value);
    notifyListeners();
  }

  void setKeepRunning(bool value) {
    keepRunning = value;
    _prefs.setBool('keepRunning', value);
    if (Platform.isIOS) unawaited(setIosKeepAlive(value));
    notifyListeners();
  }

  void setPureBlack(bool value) {
    pureBlack = value;
    _prefs.setBool('pureBlack', value);
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    _prefs.setString('themeMode', mode.name);
    notifyListeners();
  }

  void setPermissions(Permissions value) {
    permissions = value;
    _prefs
      ..setBool('allowFiles', value.files)
      ..setBool('allowInput', value.input);
    discovery.announce();
    notifyListeners();
  }

  void setReceiveDir(String? dir) {
    _receiveDir = dir;
    if (dir == null) {
      _prefs.remove('receiveDir');
    } else {
      _prefs.setString('receiveDir', dir);
    }
    notifyListeners();
  }
}

/// Whether [revealInFolder] can do anything on this platform.
bool get canRevealFiles => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Opens Explorer (or Finder) with [path] selected.
Future<void> revealInFolder(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [p.dirname(path)]);
  }
}

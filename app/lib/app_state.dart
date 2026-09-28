import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/client.dart';
import 'core/discovery.dart';
import 'core/models.dart';
import 'core/server.dart';
import 'core/trust.dart';
import 'platform/android.dart';
import 'platform/files.dart';
import 'platform/macos.dart';
import 'platform/input.dart';
import 'platform/media.dart';

enum TransferState { running, done, failed }

class Transfer {
  Transfer({required this.name, required this.upload, required this.deviceName});

  final String name;
  final bool upload;
  final String deviceName;
  int done = 0;
  int total = 0;
  TransferState state = TransferState.running;
  String? error;
  String? localPath;

  double? get fraction => total > 0 ? done / total : null;
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
  late final MediaController media = MediaController.forCurrentPlatform(input);
  late final FileService files;
  late final SidekickServer server;
  late final Discovery discovery;

  final _pairRequests = StreamController<PairingRequest>.broadcast();
  final _pairedEvents = StreamController<PairedDevice>.broadcast();
  final _notices = StreamController<Notice>.broadcast();

  /// Someone wants to pair with us: show the PIN.
  Stream<PairingRequest> get pairRequests => _pairRequests.stream;

  /// A pairing finished (either direction).
  Stream<PairedDevice> get pairedEvents => _pairedEvents.stream;
  Stream<Notice> get notices => _notices.stream;

  Timer? _presenceTimer;
  Timer? _scanTimer;

  static Future<AppState> load() async {
    final state = AppState._(await SharedPreferences.getInstance());
    state._restore();
    return state;
  }

  // ---------------------------------------------------------------- persistence

  void _restore() {
    id = _prefs.getString('id') ?? newDeviceId();
    _prefs.setString('id', id);
    name = _prefs.getString('name') ?? _defaultName();
    themeMode = ThemeMode.values.byName(_prefs.getString('themeMode') ?? 'system');
    permissions = Permissions(
      files: _prefs.getBool('allowFiles') ?? true,
      media: _prefs.getBool('allowMedia') ?? true,
      input: _prefs.getBool('allowInput') ?? true,
    );
    _receiveDir = _prefs.getString('receiveDir');
    selectedId = _prefs.getString('selectedId');
    for (final json in _prefs.getStringList('trusted') ?? const <String>[]) {
      trust.add(TrustedPeer.fromJson(jsonDecode(json) as Map<String, dynamic>));
    }
    for (final json in _prefs.getStringList('paired') ?? const <String>[]) {
      final d = PairedDevice.fromJson(jsonDecode(json) as Map<String, dynamic>);
      _paired[d.id] = d;
    }
    trust.onChanged = () => _prefs.setStringList('trusted', [for (final t in trust.peers) jsonEncode(t)]);
  }

  void _savePaired() => _prefs.setStringList('paired', [for (final d in _paired.values) jsonEncode(d)]);

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
    capabilities: Capabilities(
      files: permissions.files && (!Platform.isAndroid || AndroidBridge.permissions.allFiles),
      media: permissions.media && media.supported,
      input: permissions.input && input.supported,
    ),
  );

  Future<void> start() async {
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
    // iOS apps can only share their own Documents folder.
    files = Platform.isIOS ? FileService(home: (await getApplicationDocumentsDirectory()).path) : FileService();
    server = SidekickServer(
      self: () => me,
      trust: trust,
      files: files,
      media: media,
      input: input,
      receiveDir: receiveDir,
      permissions: () => permissions,
    );
    server.events.listen(_onServerEvent);
    try {
      await server.start();
    } on SocketException {
      // Port taken (another copy running?). Use any free port; discovery
      // announces the real one.
      try {
        await server.start(port: 0);
      } on SocketException catch (e) {
        networkError = "Couldn't start the Sidekick server: ${e.message}";
      }
    }

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

    addresses = await localAddresses();
    _presenceTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkPresence());
    unawaited(_checkPresence());
    notifyListeners();
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _scanTimer?.cancel();
    discovery.stop();
    server.stop();
    media.dispose();
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

  bool scanning = false;

  /// Asks every address on this device's /24 networks for `/v1/info`. Finds
  /// devices where multicast discovery doesn't work (iOS, some routers).
  Future<void> scanNetwork() async {
    if (scanning) return;
    scanning = true;
    notifyListeners();
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

      await Future.wait(List.generate(32, (_) => worker()));
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  static bool _isPrivate(String a) =>
      a.startsWith('10.') || a.startsWith('192.168.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a);

  // ---------------------------------------------------------------- devices

  List<PairedDevice> get paired => _paired.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  /// Devices we've heard from recently that we haven't paired with.
  List<DeviceInfo> get nearby {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 20));
    return [
      for (final n in _nearby.values)
        if (n.lastSeen.isAfter(cutoff) && !_paired.containsKey(n.info.id)) n.info,
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  PairedDevice? pairedById(String? id) => id == null ? null : _paired[id];

  /// Capabilities the device last announced, if we've seen it.
  Capabilities? capabilitiesOf(String id) => _nearby[id]?.info.capabilities;

  bool isOnline(String id) {
    final t = _lastContact[id];
    return t != null && DateTime.now().difference(t) < const Duration(seconds: 25);
  }

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

  PeerClient clientFor(PairedDevice d) => PeerClient.forDevice(d);

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
  Future<void> _checkPresence() async {
    await Future.wait([
      for (final d in _paired.values)
        if (!isOnline(d.id) && d.lastAddress != null)
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

  Future<void> requestPairing(DeviceInfo target) =>
      PeerClient(host: target.address!, port: target.port).requestPairing(me);

  Future<PairedDevice> confirmPairing(DeviceInfo target, String pin) async {
    final result = await PeerClient(host: target.address!, port: target.port).confirmPairing(id, pin);
    trust.add(
      TrustedPeer(
        id: result.device.id,
        name: result.device.name,
        platform: result.device.platform,
        token: result.tokenForThem,
      ),
    );
    _addPaired(result.device);
    return result.device;
  }

  void _addPaired(PairedDevice d) {
    _paired[d.id] = d;
    _lastContact[d.id] = DateTime.now();
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
      case Paired(:final device):
        _addPaired(device);
        _notices.add(Notice('Paired with ${device.name}'));
      case Unpaired(:final peerId):
        final name = _paired.remove(peerId)?.name;
        _savePaired();
        notifyListeners();
        if (name != null) _notices.add(Notice('$name unpaired from this device'));
      case FileReceived(:final from, :final file):
        _notices.add(Notice('Received ${p.basename(file.path)} from ${from.name}', revealPath: file.path));
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
    final t = Transfer(name: name, upload: upload, deviceName: d.name);
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
  /// the other device; otherwise into its receive folder.
  Future<void> sendFiles(PairedDevice d, List<File> localFiles, {String? remoteDir}) async {
    final client = clientFor(d);
    for (final file in localFiles) {
      final t = _startTransfer(p.basename(file.path), d, upload: true);
      try {
        await client.upload(
          file,
          name: p.basename(file.path),
          remoteDir: remoteDir,
          onProgress: (a, b) => _progress(t, a, b),
        );
        t.state = TransferState.done;
      } catch (e) {
        t
          ..state = TransferState.failed
          ..error = '$e';
      }
      notifyListeners();
    }
  }

  Future<File?> download(PairedDevice d, RemoteEntry entry) async {
    final t = _startTransfer(entry.name, d, upload: false);
    try {
      final dir = await receiveDir();
      await Directory(dir).create(recursive: true);
      final dest = await uniqueFile(dir, sanitizeFileName(entry.name));
      final file = await clientFor(d).download(entry.path, dest, onProgress: (a, b) => _progress(t, a, b));
      t
        ..state = TransferState.done
        ..localPath = file.path;
      notifyListeners();
      _notices.add(Notice('Saved ${entry.name}', revealPath: file.path));
      return file;
    } catch (e) {
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

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    _prefs.setString('themeMode', mode.name);
    notifyListeners();
  }

  void setPermissions(Permissions value) {
    permissions = value;
    _prefs
      ..setBool('allowFiles', value.files)
      ..setBool('allowMedia', value.media)
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

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'ble_backend.dart';
import 'ble_protocol.dart';
import 'models.dart';
import 'server.dart';

/// A Sidekick device seen over Bluetooth.
class BleSighting {
  BleSighting(this.info, this.bleId) : seen = DateTime.now();
  final DeviceInfo info;

  /// Its Bluetooth id (it changes when the other device restarts Bluetooth).
  final String bleId;
  DateTime seen;
}

enum BluetoothStatus { starting, on, off, unauthorized, unsupported }

/// A Sidekick device heard over Bluetooth, identified or not, for the
/// Bluetooth pairing screen.
class BleCandidate {
  BleCandidate(this.bleId);
  final String bleId;
  int rssi = 0;
  DateTime seen = DateTime.now();

  /// Who it is, once its name was read.
  DeviceInfo? info;

  /// Why reading its name failed, if it did.
  String? error;
  bool identifying = false;
}

/// Sidekick over Bluetooth LE, used when devices don't share a Wi-Fi network.
///
/// *Peripheral role:* advertises the Sidekick service and answers requests
/// by running them through the same handler as the Wi-Fi server.
/// *Central role:* scans for other Sidekick devices, reads who they are, and
/// opens request links to them on demand.
///
/// The radio itself is a [BleBackend]: Sidekick's own CoreBluetooth code on
/// iPhone and Mac, the Bluetooth plugin on Android and Windows.
class BluetoothService {
  BluetoothService({required this.self, required this.server, BleBackend? backend})
    : _ble = backend ?? BleBackend.forThisDevice();

  final DeviceInfo Function() self;
  final SidekickServer server;
  final BleBackend _ble;
  late final _dispatcher = BleRequestDispatcher(server.handleBle, keyFor: server.bleKeyFor);

  final _found = StreamController<BleSighting>.broadcast();
  final _status = StreamController<BluetoothStatus>.broadcast();

  /// Sidekick devices seen over Bluetooth (repeats included).
  Stream<BleSighting> get found => _found.stream;
  Stream<BluetoothStatus> get statusChanges => _status.stream;

  // Finding others (central) and being found (peripheral) are separate:
  // some computers can scan but not advertise, and one mustn't block the
  // other.
  BleRadio _centralState = BleRadio.unknown;
  BleRadio _peripheralState = BleRadio.unknown;

  /// Can look for other devices.
  bool get canScan => _centralState == BleRadio.on;

  /// Overall state for Settings: on if this device can find or be found.
  BluetoothStatus get status {
    final states = [_centralState, _peripheralState];
    if (states.contains(BleRadio.on)) return BluetoothStatus.on;
    if (states.contains(BleRadio.off)) return BluetoothStatus.off;
    if (states.contains(BleRadio.unauthorized)) return BluetoothStatus.unauthorized;
    if (states.every((s) => s == BleRadio.unsupported)) return BluetoothStatus.unsupported;
    return BluetoothStatus.starting;
  }

  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _advertising = false;
  bool _advertiseRunning = false;
  bool _scanning = false;

  /// Whether other devices can find this one right now.
  bool get advertising => _advertising;
  bool get scanning => _scanning;
  DateTime? lastScan;

  /// Recent events and errors, newest last, for Settings → Bluetooth.
  final List<String> log = [];

  /// Called when [log], [advertising] or [scanning] change.
  void Function()? onChanged;

  void _log(String message) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    log.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $message');
    if (log.length > 60) log.removeRange(0, log.length - 60);
    onChanged?.call();
  }

  /// Devices we've identified, by Bluetooth id.
  final Map<String, DeviceInfo> _identified = {};
  final Set<String> _identifying = {};

  Uint8List _infoBytes() => Uint8List.fromList(utf8.encode(jsonEncode(self().toJson())));

  // ------------------------------------------------------------ start / stop

  Future<void> start() async {
    _subscriptions
      ..add(_ble.stateChanged.listen((_) => _onStates()))
      ..add(_ble.messages.listen(_log))
      ..add(_ble.discovered.listen(_onDiscovered))
      ..add(_ble.notified.listen((e) => _links[e.$1]?.incoming.add(e.$2)))
      ..add(_ble.disconnected.listen((id) => _links.remove(id)?.close()))
      ..add(_ble.written.listen(_onWritten))
      ..add(
        _ble.centralGone.listen((central) {
          _dispatcher.forget(central);
          _notifyLength.remove(central);
          _feeds.remove(central);
        }),
      );
    try {
      await _ble.start(info: _infoBytes);
    } catch (e) {
      _log('Bluetooth failed to start: $e');
    }
    await refresh();
  }

  /// Re-reads both states (and this device's name for others to read).
  /// Called regularly too, since some platforms only report a change once
  /// and a missed event would leave Bluetooth "starting" forever.
  Future<void> refresh() async {
    try {
      await _ble.refresh();
    } catch (e) {
      _log('Reading the Bluetooth state failed: $e');
    }
    await _onStates();
  }

  Future<void> _onStates() async {
    final central = _ble.centralState, peripheral = _ble.peripheralState;
    if (central != _centralState) {
      _centralState = central;
      _log('Finding devices: ${central.name}');
      _status.add(status);
    }
    if (peripheral != _peripheralState) {
      _peripheralState = peripheral;
      _log('Being found: ${peripheral.name}');
      if (peripheral != BleRadio.on) _advertising = false;
      _status.add(status);
    }
    // Advertising can stop on its own (another app, the OS); try again.
    if (_peripheralState == BleRadio.on && !_advertising) await _startAdvertising();
  }

  DateTime? _lastAdvertiseFailure;

  Future<void> _startAdvertising() async {
    if (_advertising || _advertiseRunning) return;
    // Don't hammer an adapter that can't advertise; try once a minute.
    final failed = _lastAdvertiseFailure;
    if (failed != null && DateTime.now().difference(failed) < const Duration(minutes: 1)) return;
    _advertiseRunning = true;
    try {
      await _ble.advertise().timeout(const Duration(seconds: 15));
      _advertising = true;
      _lastAdvertiseFailure = null;
      _log('Advertising: other devices can find this one');
    } catch (e) {
      // Some adapters can't act as a peripheral; we can still scan.
      _lastAdvertiseFailure = DateTime.now();
      _log("Can't advertise, so other devices won't find this one (it can still find them): ${_describe(e)}");
    } finally {
      _advertiseRunning = false;
      onChanged?.call();
    }
  }

  /// Asks the OS for Bluetooth permission again, or opens the app's
  /// settings if it was denied for good.
  Future<void> requestPermission() async {
    try {
      await _ble.requestPermission();
    } catch (_) {}
  }

  Future<void> stop() async {
    _searching = false;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    for (final link in _links.values) {
      await link.close();
    }
    _links.clear();
    try {
      await _ble.stop();
    } catch (_) {}
  }

  static String _describe(Object e) => switch (e) {
    TimeoutException() => 'it took too long to answer',
    StateError(:final message) => message,
    _ => '$e'.replaceFirst(RegExp(r'^PlatformException\(\w+, '), '').replaceFirst(RegExp(r', null, null\)$'), ''),
  };

  // ------------------------------------------------------------ peripheral role

  final Map<String, Future<int>> _notifyLength = {};
  final Map<String, Future<void>> _feeds = {};

  /// Feeds request chunks to the dispatcher strictly in the order they
  /// arrived (the first one waits for the packet size).
  void _onWritten((String, Uint8List) e) {
    final (central, chunk) = e;
    final length = _notifyLength[central] ??= _ble.maxNotify(central).catchError((Object _) => 20);
    _feeds[central] = (_feeds[central] ?? Future.value()).then((_) async {
      final maxChunk = await length;
      // Not awaited: the chunk is taken in right away, answering can take
      // a while and mustn't hold up the next request.
      unawaited(
        _dispatcher
            .onChunk(central, chunk, maxChunk: maxChunk, sendChunk: (response) => _ble.notify(central, response))
            .catchError((Object err) => _log('Answering a Bluetooth request failed: ${_describe(err)}')),
      );
    });
  }

  // ------------------------------------------------------------ central role

  /// Scans for Sidekick devices for [duration].
  Future<void> scan({Duration duration = const Duration(seconds: 8)}) async {
    if (!canScan) {
      _log("Can't look for devices: Bluetooth is ${_centralState.name}");
      return;
    }
    if (_scanning) return;
    _scanning = true;
    _seenThisScan = 0;
    _seenAny.clear();
    // Every other scan listens to *all* devices and picks out Sidekick
    // ones itself (by service id or name): it works even where filtered
    // scans miss a device, and tells apart "nothing on the air at all"
    // from "devices around, but none running Sidekick".
    _unfiltered = !_unfiltered;
    onChanged?.call();
    try {
      await _ble.startScan(filtered: !_unfiltered);
      await Future<void>.delayed(duration);
      if (_unfiltered) {
        lastDevicesAround = _seenAny.length;
        _log('Listened to everything: ${_seenAny.length} Bluetooth device(s) around, $_seenThisScan from Sidekick');
      } else {
        _log('Looked for Sidekick: $_seenThisScan found');
      }
    } catch (e) {
      _log('Scan failed: ${_describe(e)}');
    } finally {
      try {
        await _ble.stopScan();
      } catch (_) {}
      _scanning = false;
      lastScan = DateTime.now();
      onChanged?.call();
    }
  }

  int _seenThisScan = 0;
  bool _unfiltered = false;
  final Set<String> _seenAny = {};

  /// How many Bluetooth devices of any kind the last full scan heard (null
  /// before one ran). Zero means this device hears nothing at all.
  int? lastDevicesAround;

  final Set<String> _everSeen = {};

  /// Every Sidekick device heard, by Bluetooth id.
  final Map<String, BleCandidate> candidates = {};

  bool _searching = false;
  bool get searching => _searching;

  /// Keeps scanning until [stopSearch] (the Bluetooth pairing screen is
  /// open), instead of the short periodic scans.
  Future<void> startSearch() async {
    if (_searching) return;
    _searching = true;
    onChanged?.call();
    while (_searching) {
      final started = DateTime.now();
      if (canScan) {
        await scan(duration: const Duration(seconds: 10));
      } else {
        await refresh();
      }
      // Never spin: scan() returns at once when another scan is already
      // running (or fails right away), and a loop of instantly completed
      // awaits starves the UI, freezing the app.
      final elapsed = DateTime.now().difference(started);
      if (elapsed < const Duration(seconds: 1)) {
        await Future<void>.delayed(const Duration(seconds: 1) - elapsed);
      }
    }
  }

  /// Safe to call while a screen is closing: it doesn't redraw anything
  /// right away.
  void stopSearch() {
    _searching = false;
    scheduleMicrotask(() => onChanged?.call());
  }

  /// Tries reading a device's name again after it failed.
  void retry(String key) {
    final c = candidates[key];
    if (c == null || c.identifying) return;
    c.error = null;
    _identified.remove(key);
    if (_identifying.add(key)) unawaited(_identify(key).whenComplete(() => _identifying.remove(key)));
  }

  void _onDiscovered(BleDiscovery d) {
    final key = d.id;
    _seenAny.add(key);
    if (!d.sidekick) return;
    _seenThisScan++;
    final candidate = candidates.putIfAbsent(key, () => BleCandidate(key))
      ..rssi = d.rssi
      ..seen = DateTime.now();
    onChanged?.call();
    // A failed device isn't retried on every advertisement; Retry does it.
    if (candidate.error != null && _identified[key] == null) return;
    if (_everSeen.add(key)) _log('In range: a Sidekick device (signal ${d.rssi} dBm), asking its name…');
    final known = _identified[key];
    if (known != null) {
      if (known.id != self().id) _found.add(BleSighting(known, key));
      return;
    }
    if (_identifying.add(key)) unawaited(_identify(key).whenComplete(() => _identifying.remove(key)));
  }

  /// Connects briefly to read who a newly seen device is. Only the minimum
  /// (connect, find the service, read one value) so that as few things as
  /// possible can go wrong; request links set up the rest later.
  Future<void> _identify(String key) async {
    final candidate = candidates[key]
      ?..identifying = true
      ..error = null;
    onChanged?.call();
    try {
      final raw = await _ble.identify(key).timeout(const Duration(seconds: 20));
      final info = DeviceInfo.fromJson(jsonDecode(utf8.decode(raw)) as Map<String, dynamic>);
      _identified[key] = info;
      candidate?.info = info;
      if (info.id != self().id) {
        _log('Found ${info.name} (${info.platform.name})');
        _found.add(BleSighting(info, key));
      }
    } catch (e) {
      // A connection that never happens would otherwise stay pending.
      if (e is TimeoutException && !_links.containsKey(key)) unawaited(_ble.close(key).catchError((_) {}));
      _log('A Sidekick device is in range but reading its name failed: ${_describe(e)}');
      candidate?.error = e is FormatException ? 'It runs an older Sidekick' : _describe(e);
    } finally {
      candidate?.identifying = false;
      onChanged?.call();
    }
  }

  final Map<String, _Link> _links = {};
  final Map<String, Future<_Link>> _opening = {};

  Future<_Link> _link(String id) {
    final existing = _links[id];
    if (existing != null) return Future.value(existing);
    return _opening[id] ??= () async {
      try {
        // Twice: the first try can meet the tail of the short connection
        // that read the device's name, which is still hanging up.
        for (var attempt = 1; ; attempt++) {
          try {
            final maxWrite = await _ble.open(id).timeout(const Duration(seconds: 20));
            return _links[id] = _Link(_ble, id, maxWrite);
          } catch (e) {
            unawaited(_ble.close(id).catchError((_) {}));
            _log('Connecting over Bluetooth failed: ${_describe(e)}');
            if (attempt >= 2) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
      } finally {
        unawaited(_opening.remove(id));
      }
    }();
  }

  /// A request client for the device with Bluetooth id [id]. It connects on
  /// first use and reconnects if the link drops.
  BleRpcClient clientFor(String id) {
    final incoming = StreamController<Uint8List>();
    StreamSubscription<Uint8List>? relay;
    Future<_Link> ready() async {
      final link = await _link(id);
      relay ??= link.incoming.stream.listen(incoming.add, onDone: () => relay = null);
      return link;
    }

    return BleRpcClient(
      incoming: incoming.stream,
      chunkSize: () async => (await ready()).maxWrite,
      send: (chunk) async => (await ready()).write(chunk),
    );
  }
}

/// One connection from us (central) to another device's Sidekick service.
class _Link {
  _Link(this._ble, this.id, this.maxWrite);

  final BleBackend _ble;
  final String id;
  final int maxWrite;
  final incoming = StreamController<Uint8List>.broadcast();

  Future<void> write(Uint8List chunk) => _ble.write(id, chunk).timeout(const Duration(seconds: 15));

  Future<void> close() async {
    await incoming.close();
    try {
      await _ble.close(id);
    } catch (_) {}
  }
}

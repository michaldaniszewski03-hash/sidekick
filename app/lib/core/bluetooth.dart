import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'ble_protocol.dart';
import 'models.dart';
import 'server.dart';

/// A Sidekick device seen over Bluetooth.
class BleSighting {
  BleSighting(this.info, this.peripheral) : seen = DateTime.now();
  final DeviceInfo info;
  final Peripheral peripheral;
  DateTime seen;
}

enum BluetoothStatus { starting, on, off, unauthorized, unsupported }

/// A Sidekick device heard over Bluetooth, identified or not, for the
/// Bluetooth pairing screen.
class BleCandidate {
  BleCandidate(this.peripheral);
  Peripheral peripheral;
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
class BluetoothService {
  BluetoothService({required this.self, required this.server});

  final DeviceInfo Function() self;
  final SidekickServer server;

  final _peripheralManager = PeripheralManager();
  final _centralManager = CentralManager();
  late final _dispatcher = BleRequestDispatcher(server.handleBle, keyFor: server.bleKeyFor);

  final _found = StreamController<BleSighting>.broadcast();
  final _status = StreamController<BluetoothStatus>.broadcast();

  /// Sidekick devices seen over Bluetooth (repeats included).
  Stream<BleSighting> get found => _found.stream;
  Stream<BluetoothStatus> get statusChanges => _status.stream;

  // Finding others (central) and being found (peripheral) are separate:
  // some computers can scan but not advertise, and one mustn't block the
  // other.
  BluetoothLowEnergyState _centralState = BluetoothLowEnergyState.unknown;
  BluetoothLowEnergyState _peripheralState = BluetoothLowEnergyState.unknown;

  /// Can look for other devices.
  bool get canScan => _centralState == BluetoothLowEnergyState.poweredOn;

  /// Overall state for Settings: on if this device can find or be found.
  BluetoothStatus get status {
    final states = [_centralState, _peripheralState];
    if (states.contains(BluetoothLowEnergyState.poweredOn)) return BluetoothStatus.on;
    if (states.contains(BluetoothLowEnergyState.poweredOff)) return BluetoothStatus.off;
    if (states.contains(BluetoothLowEnergyState.unauthorized)) return BluetoothStatus.unauthorized;
    if (states.every((s) => s == BluetoothLowEnergyState.unsupported)) return BluetoothStatus.unsupported;
    return BluetoothStatus.starting;
  }

  late final GATTCharacteristic _info = GATTCharacteristic.mutable(
    uuid: bleInfoUuid,
    properties: [GATTCharacteristicProperty.read],
    permissions: [GATTCharacteristicPermission.read],
    descriptors: [],
  );
  late final GATTCharacteristic _rx = GATTCharacteristic.mutable(
    uuid: bleRxUuid,
    properties: [GATTCharacteristicProperty.write, GATTCharacteristicProperty.writeWithoutResponse],
    permissions: [GATTCharacteristicPermission.write],
    descriptors: [],
  );
  late final GATTCharacteristic _tx = GATTCharacteristic.mutable(
    uuid: bleTxUuid,
    properties: [GATTCharacteristicProperty.notify],
    permissions: [GATTCharacteristicPermission.read],
    descriptors: [],
  );

  final _subscriptions = <StreamSubscription<Object>>[];
  bool _advertising = false;
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

  /// Peripherals we've identified, by Bluetooth UUID.
  final Map<String, DeviceInfo> _identified = {};
  final Set<String> _identifying = {};

  // ------------------------------------------------------------ start / stop

  Future<void> start() async {
    for (final authorize in [_peripheralManager.authorize, _centralManager.authorize]) {
      try {
        final ok = await authorize();
        if (!ok) _log('Bluetooth permission was not granted');
      } on UnsupportedError {
        // Only Android asks at runtime; Apple platforms prompt on first use.
      } catch (e) {
        _log('Asking for Bluetooth permission failed: $e');
      }
    }
    _subscriptions
      ..add(_peripheralManager.stateChanged.listen((e) => _onPeripheralState(e.state)))
      ..add(_centralManager.stateChanged.listen((e) => _onCentralState(e.state)))
      ..add(_peripheralManager.characteristicReadRequested.listen(_onRead))
      ..add(_peripheralManager.characteristicWriteRequested.listen(_onWrite))
      ..add(
        _peripheralManager.connectionStateChanged.listen((e) {
          if (e.state == ConnectionState.disconnected) _dispatcher.forget('${e.central.uuid}');
        }),
      )
      ..add(_centralManager.discovered.listen(_onDiscovered))
      ..add(_centralManager.characteristicNotified.listen(_onNotified))
      ..add(
        _centralManager.connectionStateChanged.listen((e) {
          if (e.state == ConnectionState.disconnected) _links.remove('${e.peripheral.uuid}')?.close();
        }),
      );
    await refresh();
  }

  /// Re-reads both states. Called regularly too, since some platforms only
  /// report a change once and a missed event would leave Bluetooth "starting"
  /// forever.
  Future<void> refresh() async {
    try {
      await _onCentralState(_centralManager.state);
    } catch (_) {}
    try {
      await _onPeripheralState(_peripheralManager.state);
    } catch (_) {}
    // Advertising can stop on its own (another app, the OS); try again.
    if (_peripheralState == BluetoothLowEnergyState.poweredOn && !_advertising) await _startAdvertising();
  }

  Future<void> _onCentralState(BluetoothLowEnergyState state) async {
    if (state == _centralState) return;
    _centralState = state;
    _log('Finding devices: ${state.name}');
    _status.add(status);
  }

  Future<void> _onPeripheralState(BluetoothLowEnergyState state) async {
    if (state == _peripheralState) return;
    _peripheralState = state;
    _log('Being found: ${state.name}');
    _status.add(status);
    if (state == BluetoothLowEnergyState.poweredOn) {
      await _startAdvertising();
    } else {
      _advertising = false;
    }
  }

  Future<void> _startAdvertising() async {
    if (_advertising) return;
    try {
      await _peripheralManager.removeAllServices();
      await _peripheralManager.addService(
        GATTService(uuid: bleServiceUuid, isPrimary: true, includedServices: [], characteristics: [_info, _rx, _tx]),
      );
      // Just the service UUID: advertisements are tiny (31 bytes), and
      // iPhones/Macs can't advertise anything else. Names come from `info`.
      await _peripheralManager.startAdvertising(
        Advertisement(
          // iPhones and Macs also advertise the name "Sidekick", so they can
          // be recognized even when a scanner doesn't get the service id.
          // (On Android a name here would rename the phone's Bluetooth.)
          name: Platform.isIOS || Platform.isMacOS ? advertisedName : null,
          serviceUUIDs: [bleServiceUuid],
        ),
      );
      _advertising = true;
      _log('Advertising: other devices can find this one');
    } catch (e) {
      // Some adapters can't act as a peripheral; we can still scan.
      _log("Can't advertise, so other devices won't find this one (it can still find them): $e");
    }
  }

  /// Asks the OS for Bluetooth permission again, or opens the app's
  /// settings if it was denied for good.
  Future<void> requestPermission() async {
    try {
      final ok = await _centralManager.authorize();
      if (!ok) await _centralManager.showAppSettings();
    } on UnsupportedError {
      try {
        await _centralManager.showAppSettings();
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> stop() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    for (final link in _links.values) {
      await link.close();
    }
    _links.clear();
    try {
      await _peripheralManager.stopAdvertising();
      if (_scanning) await _centralManager.stopDiscovery();
    } catch (_) {}
  }

  // ------------------------------------------------------------ peripheral role

  Future<void> _onRead(GATTCharacteristicReadRequestedEventArgs e) async {
    try {
      if (e.characteristic.uuid != bleInfoUuid) {
        await _peripheralManager.respondReadRequestWithError(e.request, error: GATTError.readNotPermitted);
        return;
      }
      final value = Uint8List.fromList(utf8.encode(jsonEncode(self().toJson())));
      final offset = e.request.offset.clamp(0, value.length);
      await _peripheralManager.respondReadRequestWithValue(e.request, value: Uint8List.sublistView(value, offset));
    } catch (_) {}
  }

  final Map<String, int> _notifyLength = {};

  Future<void> _onWrite(GATTCharacteristicWriteRequestedEventArgs e) async {
    if (e.characteristic.uuid != bleRxUuid) {
      try {
        await _peripheralManager.respondWriteRequestWithError(e.request, error: GATTError.writeNotPermitted);
      } catch (_) {}
      return;
    }
    try {
      await _peripheralManager.respondWriteRequest(e.request);
    } catch (_) {
      // Writes without response need no answer.
    }
    final central = e.central;
    final key = '${central.uuid}';
    final maxChunk = _notifyLength[key] ??= await _maxNotify(central);
    await _dispatcher.onChunk(
      key,
      e.request.value,
      maxChunk: maxChunk,
      sendChunk: (chunk) => _peripheralManager.notifyCharacteristic(central, _tx, value: chunk),
    );
  }

  Future<int> _maxNotify(Central central) async {
    try {
      return (await _peripheralManager.getMaximumNotifyLength(central)).clamp(20, 512);
    } catch (_) {
      return 20;
    }
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
      await _centralManager.startDiscovery(serviceUUIDs: _unfiltered ? null : [bleServiceUuid]);
      await Future<void>.delayed(duration);
      if (_unfiltered) {
        lastDevicesAround = _seenAny.length;
        _log('Listened to everything: ${_seenAny.length} Bluetooth device(s) around, $_seenThisScan from Sidekick');
      } else {
        _log('Looked for Sidekick: $_seenThisScan found');
      }
    } catch (e) {
      _log('Scan failed: $e');
    } finally {
      try {
        await _centralManager.stopDiscovery();
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

  static const advertisedName = 'Sidekick';

  static bool isSidekick(Advertisement a) => a.serviceUUIDs.contains(bleServiceUuid) || a.name == advertisedName;

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
    if (_identifying.add(key)) unawaited(_identify(c.peripheral).whenComplete(() => _identifying.remove(key)));
  }

  void _onDiscovered(DiscoveredEventArgs e) {
    final key = '${e.peripheral.uuid}';
    _seenAny.add(key);
    // Filtered scans only report Sidekick devices; unfiltered ones report
    // everything, so check.
    if (_unfiltered && !isSidekick(e.advertisement)) return;
    _seenThisScan++;
    final candidate = candidates.putIfAbsent(key, () => BleCandidate(e.peripheral))
      ..peripheral = e.peripheral
      ..rssi = e.rssi
      ..seen = DateTime.now();
    onChanged?.call();
    // A failed device isn't retried on every advertisement; Retry does it.
    if (candidate.error != null && _identified[key] == null) return;
    if (_everSeen.add(key)) _log('In range: a Sidekick device (signal ${e.rssi} dBm), asking its name…');
    final known = _identified[key];
    if (known != null) {
      if (known.id != self().id) _found.add(BleSighting(known, e.peripheral));
      return;
    }
    if (_identifying.add(key)) unawaited(_identify(e.peripheral).whenComplete(() => _identifying.remove(key)));
  }

  /// Connects briefly to read who a newly seen peripheral is. Only the
  /// minimum (connect, find the service, read one value) so that as few
  /// things as possible can go wrong; request links set up the rest later.
  Future<void> _identify(Peripheral peripheral) async {
    final key = '${peripheral.uuid}';
    // An open request link already knows the way.
    final open = _links[key];
    final candidate = candidates[key]
      ?..identifying = true
      ..error = null;
    onChanged?.call();
    try {
      final Uint8List raw;
      if (open != null) {
        raw = await open.readInfo();
      } else {
        await _centralManager.connect(peripheral).timeout(const Duration(seconds: 15));
        final services = await _centralManager.discoverGATT(peripheral).timeout(const Duration(seconds: 15));
        final service = services.where((s) => s.uuid == bleServiceUuid).firstOrNull;
        if (service == null) throw StateError('it has no Sidekick service');
        final info = service.characteristics.where((c) => c.uuid == bleInfoUuid).firstOrNull;
        if (info == null) throw StateError('it has no info characteristic');
        raw = await _centralManager.readCharacteristic(peripheral, info).timeout(const Duration(seconds: 10));
      }
      final info = DeviceInfo.fromJson(jsonDecode(utf8.decode(raw)) as Map<String, dynamic>);
      _identified[key] = info;
      candidate?.info = info;
      if (info.id != self().id) {
        _log('Found ${info.name} (${info.platform.name})');
        _found.add(BleSighting(info, peripheral));
      }
    } catch (e) {
      // Not reachable right now; we'll try again when it shows up again.
      _log("A Sidekick device is in range but reading its name failed: $e");
      candidate?.error = e is TimeoutException ? 'It took too long to answer' : '$e';
    } finally {
      candidate?.identifying = false;
      onChanged?.call();
      // Don't hold the connection just for a name; phones allow only a few.
      if (open == null) {
        try {
          await _centralManager.disconnect(peripheral);
        } catch (_) {}
      }
    }
  }

  final Map<String, _Link> _links = {};

  Future<_Link> _link(Peripheral peripheral) async {
    final key = '${peripheral.uuid}';
    final existing = _links[key];
    if (existing != null) return existing;
    final link = await _Link.open(_centralManager, peripheral);
    _links[key] = link;
    return link;
  }

  void _onNotified(GATTCharacteristicNotifiedEventArgs e) {
    if (e.characteristic.uuid != bleTxUuid) return;
    _links['${e.peripheral.uuid}']?.incoming.add(e.value);
  }

  /// A request client for [peripheral]. It connects on first use and
  /// reconnects if the link drops.
  BleRpcClient clientFor(Peripheral peripheral) {
    final incoming = StreamController<Uint8List>();
    StreamSubscription<Uint8List>? relay;
    Future<_Link> ready() async {
      final link = await _link(peripheral);
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
  _Link._(this._central, this.peripheral, this._rx, this._info, this.maxWrite);

  final CentralManager _central;
  final Peripheral peripheral;
  final GATTCharacteristic _rx;
  final GATTCharacteristic _info;
  final int maxWrite;
  final incoming = StreamController<Uint8List>.broadcast();

  static Future<_Link> open(CentralManager central, Peripheral peripheral) async {
    await central.connect(peripheral).timeout(const Duration(seconds: 15));
    try {
      await central.requestMTU(peripheral, mtu: 517);
    } catch (_) {
      // Only Android lets apps ask; elsewhere the OS negotiates.
    }
    final services = await central.discoverGATT(peripheral);
    final service = services.firstWhere((s) => s.uuid == bleServiceUuid);
    GATTCharacteristic find(UUID id) => service.characteristics.firstWhere((c) => c.uuid == id);
    final rx = find(bleRxUuid);
    final tx = find(bleTxUuid);
    await central.setCharacteristicNotifyState(peripheral, tx, state: true);
    int maxWrite;
    try {
      maxWrite = await central.getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withResponse);
    } catch (_) {
      maxWrite = 20;
    }
    return _Link._(central, peripheral, rx, find(bleInfoUuid), maxWrite.clamp(20, 512));
  }

  Future<Uint8List> readInfo() => _central.readCharacteristic(peripheral, _info);

  Future<void> write(Uint8List chunk) => _central.writeCharacteristic(
    peripheral,
    _rx,
    value: chunk,
    // With response: slower, but nothing gets dropped when buffers fill.
    type: GATTCharacteristicWriteType.withResponse,
  );

  Future<void> close() async {
    await incoming.close();
    try {
      await _central.disconnect(peripheral);
    } catch (_) {}
  }
}

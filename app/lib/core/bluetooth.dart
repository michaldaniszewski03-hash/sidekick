import 'dart:async';
import 'dart:convert';
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
  BluetoothStatus status = BluetoothStatus.starting;

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

  /// Peripherals we've identified, by Bluetooth UUID.
  final Map<String, DeviceInfo> _identified = {};
  final Set<String> _identifying = {};

  // ------------------------------------------------------------ start / stop

  Future<void> start() async {
    for (final authorize in [_peripheralManager.authorize, _centralManager.authorize]) {
      try {
        await authorize();
      } on UnsupportedError {
        // Only Android asks at runtime; Apple platforms prompt on first use.
      } catch (_) {}
    }
    _subscriptions
      ..add(_peripheralManager.stateChanged.listen((e) => _onState(e.state)))
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
    await _onState(_peripheralManager.state);
  }

  Future<void> _onState(BluetoothLowEnergyState state) async {
    status = switch (state) {
      BluetoothLowEnergyState.poweredOn => BluetoothStatus.on,
      BluetoothLowEnergyState.poweredOff => BluetoothStatus.off,
      BluetoothLowEnergyState.unauthorized => BluetoothStatus.unauthorized,
      BluetoothLowEnergyState.unsupported => BluetoothStatus.unsupported,
      BluetoothLowEnergyState.unknown => BluetoothStatus.starting,
    };
    _status.add(status);
    if (status == BluetoothStatus.on) {
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
      await _peripheralManager.startAdvertising(Advertisement(serviceUUIDs: [bleServiceUuid]));
      _advertising = true;
    } catch (_) {
      // Some adapters can't act as a peripheral; we can still scan.
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
    if (status != BluetoothStatus.on || _scanning) return;
    _scanning = true;
    try {
      await _centralManager.startDiscovery(serviceUUIDs: [bleServiceUuid]);
      await Future<void>.delayed(duration);
    } catch (_) {
      // Scanning not allowed right now; try again next round.
    } finally {
      try {
        await _centralManager.stopDiscovery();
      } catch (_) {}
      _scanning = false;
    }
  }

  void _onDiscovered(DiscoveredEventArgs e) {
    final key = '${e.peripheral.uuid}';
    final known = _identified[key];
    if (known != null) {
      if (known.id != self().id) _found.add(BleSighting(known, e.peripheral));
      return;
    }
    if (_identifying.add(key)) unawaited(_identify(e.peripheral).whenComplete(() => _identifying.remove(key)));
  }

  /// Connects briefly to read who a newly seen peripheral is.
  Future<void> _identify(Peripheral peripheral) async {
    final key = '${peripheral.uuid}';
    try {
      final link = await _link(peripheral);
      final info = DeviceInfo.fromJson(jsonDecode(utf8.decode(await link.readInfo())) as Map<String, dynamic>);
      _identified[key] = info;
      if (info.id != self().id) _found.add(BleSighting(info, peripheral));
    } catch (_) {
      // Not reachable right now; we'll try again when it shows up again.
    } finally {
      // Don't hold the connection just for a name; phones allow only a few.
      await _links.remove(key)?.close();
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

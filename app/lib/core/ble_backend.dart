import 'dart:async';
import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/services.dart';

import 'ble_protocol.dart';

/// What a Bluetooth radio role can do right now.
enum BleRadio { unknown, on, off, unauthorized, unsupported }

/// A device heard while scanning.
class BleDiscovery {
  const BleDiscovery({required this.id, required this.rssi, required this.sidekick, bool? strong, this.name})
    : strong = strong ?? sidekick;
  final String id;
  final int rssi;

  /// Might be Sidekick, so it's worth asking who it is.
  final bool sidekick;

  /// Really advertises the Sidekick service or name. On Apple devices a
  /// background app's services only show in a shared bitmask that other
  /// devices can match by accident; those are [sidekick] but not [strong].
  final bool strong;
  final String? name;
}

/// The Bluetooth radio, as [BluetoothService] needs it. Devices are plain
/// string ids.
///
/// * iPhone and Mac: [AppleBleBackend], Sidekick's own CoreBluetooth code
///   (ios/Runner/SidekickBLE.swift). The Bluetooth plugin never reported a
///   single device on Apple devices, so Sidekick talks to CoreBluetooth
///   directly there.
/// * Android and Windows: [PluginBleBackend] on the bluetooth_low_energy
///   plugin.
///
/// Writes are at most one packet ([open] returns the size), so a peripheral
/// always gets whole chunks.
abstract class BleBackend {
  factory BleBackend.forThisDevice() => Platform.isIOS || Platform.isMacOS ? AppleBleBackend() : PluginBleBackend();

  /// Finding others.
  BleRadio get centralState;

  /// Being found.
  BleRadio get peripheralState;
  Stream<void> get stateChanged;

  Stream<BleDiscovery> get discovered;

  /// Response chunks from a device we [open]ed: (id, chunk).
  Stream<(String, Uint8List)> get notified;

  /// A device we [open]ed disconnected.
  Stream<String> get disconnected;

  /// Request chunks another device wrote to us: (central id, chunk).
  Stream<(String, Uint8List)> get written;

  /// A device that wrote to us went away.
  Stream<String> get centralGone;

  /// What the native side wants in the Bluetooth log.
  Stream<String> get messages;

  /// [info] is this device's info JSON, served to anyone who reads it.
  Future<void> start({required Uint8List Function() info});

  /// Re-reads the radio states and this device's info.
  Future<void> refresh();
  Future<void> advertise();
  Future<void> stopAdvertising();
  Future<void> startScan({required bool filtered});
  Future<void> stopScan();

  /// Connects just long enough to read who [id] is.
  Future<Uint8List> identify(String id);

  /// Opens a request link to [id]; returns the most bytes one write carries.
  Future<int> open(String id);
  Future<Uint8List> readInfo(String id);
  Future<void> write(String id, Uint8List chunk);
  Future<void> close(String id);

  /// Sends a response chunk to a device that wrote to us.
  Future<void> notify(String central, Uint8List chunk);
  Future<int> maxNotify(String central);
  Future<void> requestPermission();

  /// The system's Bluetooth settings (Mac and Windows; phones can't be
  /// sent there directly).
  Future<void> openBluetoothSettings();
  Future<void> stop();
}

// ------------------------------------------------------------------ Apple

class AppleBleBackend implements BleBackend {
  static const _methods = MethodChannel('sidekick/ble');
  static const _events = EventChannel('sidekick/ble/events');

  @override
  BleRadio centralState = BleRadio.unknown;
  @override
  BleRadio peripheralState = BleRadio.unknown;

  final _state = StreamController<void>.broadcast();
  final _discovered = StreamController<BleDiscovery>.broadcast();
  final _notified = StreamController<(String, Uint8List)>.broadcast();
  final _disconnected = StreamController<String>.broadcast();
  final _written = StreamController<(String, Uint8List)>.broadcast();
  final _centralGone = StreamController<String>.broadcast();
  final _messages = StreamController<String>.broadcast();
  StreamSubscription<Object?>? _subscription;
  Uint8List Function()? _info;
  Uint8List? _sentInfo;

  @override
  Stream<void> get stateChanged => _state.stream;
  @override
  Stream<BleDiscovery> get discovered => _discovered.stream;
  @override
  Stream<(String, Uint8List)> get notified => _notified.stream;
  @override
  Stream<String> get disconnected => _disconnected.stream;
  @override
  Stream<(String, Uint8List)> get written => _written.stream;
  @override
  Stream<String> get centralGone => _centralGone.stream;
  @override
  Stream<String> get messages => _messages.stream;

  static BleRadio _radio(Object? name) => BleRadio.values.where((r) => r.name == name).firstOrNull ?? BleRadio.unknown;

  void _onEvent(Object? raw) {
    if (raw is! Map) return;
    final e = raw.cast<Object?, Object?>();
    Uint8List bytes() => e['data'] as Uint8List? ?? Uint8List(0);
    switch (e['type']) {
      case 'state':
        _setStates(e['central'], e['peripheral']);
      case 'discovered':
        final name = e['name'] as String?;
        _discovered.add(
          BleDiscovery(
            id: e['id'] as String,
            rssi: (e['rssi'] as num?)?.toInt() ?? 0,
            sidekick: e['sidekick'] == true,
            strong: e['strong'] as bool?,
            name: name == null || name.isEmpty ? null : name,
          ),
        );
      case 'notified':
        _notified.add((e['id'] as String, bytes()));
      case 'disconnected':
        _disconnected.add(e['id'] as String);
      case 'written':
        _written.add((e['central'] as String, bytes()));
      case 'centralGone':
        _centralGone.add(e['central'] as String);
      case 'log':
        _messages.add('${e['message']}');
    }
  }

  void _setStates(Object? central, Object? peripheral) {
    final c = _radio(central), p = _radio(peripheral);
    if (c == centralState && p == peripheralState) return;
    centralState = c;
    peripheralState = p;
    _state.add(null);
  }

  @override
  Future<void> start({required Uint8List Function() info}) async {
    _info = info;
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) => _messages.add('Bluetooth events failed: $e'),
    );
    // Before anything starts, so the first device to read it gets a name.
    final first = info();
    await _methods.invokeMethod<void>('setInfo', {'data': first});
    _sentInfo = first;
    await _methods.invokeMethod<void>('start');
    await refresh();
  }

  @override
  Future<void> refresh() async {
    final states = await _methods.invokeMapMethod<String, Object?>('state');
    if (states != null) _setStates(states['central'], states['peripheral']);
    final info = _info?.call();
    if (info != null && !_sameBytes(info, _sentInfo)) {
      await _methods.invokeMethod<void>('setInfo', {'data': info});
      _sentInfo = info;
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<void> advertise() => _methods.invokeMethod<void>('advertise');
  @override
  Future<void> stopAdvertising() => _methods.invokeMethod<void>('stopAdvertising');
  @override
  Future<void> startScan({required bool filtered}) => _methods.invokeMethod<void>('scan', {'filtered': filtered});
  @override
  Future<void> stopScan() => _methods.invokeMethod<void>('stopScan');

  @override
  Future<Uint8List> identify(String id) async =>
      (await _methods.invokeMethod<Uint8List>('identify', {'id': id})) ?? Uint8List(0);

  @override
  Future<int> open(String id) async => ((await _methods.invokeMethod<int>('open', {'id': id})) ?? 20).clamp(20, 512);

  @override
  Future<Uint8List> readInfo(String id) async =>
      (await _methods.invokeMethod<Uint8List>('readInfo', {'id': id})) ?? Uint8List(0);

  @override
  Future<void> write(String id, Uint8List chunk) => _methods.invokeMethod<void>('write', {'id': id, 'data': chunk});
  @override
  Future<void> close(String id) => _methods.invokeMethod<void>('close', {'id': id});

  @override
  Future<void> notify(String central, Uint8List chunk) =>
      _methods.invokeMethod<void>('notify', {'central': central, 'data': chunk});

  @override
  Future<int> maxNotify(String central) async =>
      ((await _methods.invokeMethod<int>('maxNotify', {'central': central})) ?? 20).clamp(20, 512);

  @override
  Future<void> requestPermission() => _methods.invokeMethod<void>('openSettings');

  @override
  Future<void> openBluetoothSettings() => _methods.invokeMethod<void>('openBluetoothSettings');

  @override
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stopScan');
      await _methods.invokeMethod<void>('stopAdvertising');
    } catch (_) {}
    await _subscription?.cancel();
  }
}

// ------------------------------------------------------------------ plugin

class PluginBleBackend implements BleBackend {
  final _peripheralManager = PeripheralManager();
  final _centralManager = CentralManager();

  BluetoothLowEnergyState _central = BluetoothLowEnergyState.unknown;
  BluetoothLowEnergyState _peripheral = BluetoothLowEnergyState.unknown;

  static BleRadio _radio(BluetoothLowEnergyState s) => switch (s) {
    BluetoothLowEnergyState.poweredOn => BleRadio.on,
    BluetoothLowEnergyState.poweredOff => BleRadio.off,
    BluetoothLowEnergyState.unauthorized => BleRadio.unauthorized,
    BluetoothLowEnergyState.unsupported => BleRadio.unsupported,
    _ => BleRadio.unknown,
  };

  @override
  BleRadio get centralState => _radio(_central);
  @override
  BleRadio get peripheralState => _radio(_peripheral);

  final _state = StreamController<void>.broadcast();
  final _discovered = StreamController<BleDiscovery>.broadcast();
  final _notified = StreamController<(String, Uint8List)>.broadcast();
  final _disconnected = StreamController<String>.broadcast();
  final _written = StreamController<(String, Uint8List)>.broadcast();
  final _centralGone = StreamController<String>.broadcast();
  final _messages = StreamController<String>.broadcast();

  @override
  Stream<void> get stateChanged => _state.stream;
  @override
  Stream<BleDiscovery> get discovered => _discovered.stream;
  @override
  Stream<(String, Uint8List)> get notified => _notified.stream;
  @override
  Stream<String> get disconnected => _disconnected.stream;
  @override
  Stream<(String, Uint8List)> get written => _written.stream;
  @override
  Stream<String> get centralGone => _centralGone.stream;
  @override
  Stream<String> get messages => _messages.stream;

  late Uint8List Function() _info;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final Map<String, Peripheral> _peripherals = {};
  final Map<String, Central> _centrals = {};
  final Map<String, _Gatt> _gatt = {};
  final Set<String> _open = {};

  late final GATTCharacteristic _infoCharacteristic = GATTCharacteristic.mutable(
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

  @override
  Future<void> start({required Uint8List Function() info}) async {
    _info = info;
    for (final authorize in [_peripheralManager.authorize, _centralManager.authorize]) {
      try {
        final ok = await authorize();
        if (!ok) _messages.add('Bluetooth permission was not granted');
      } on UnsupportedError {
        // Only Android asks at runtime.
      } catch (e) {
        _messages.add('Asking for Bluetooth permission failed: $e');
      }
    }
    // One at a time: each platform leaves some events out (Windows throws
    // for connectionStateChanged), and one missing must not stop the rest.
    void listen<T>(Stream<T> Function() stream, void Function(T) onEvent) {
      try {
        _subscriptions.add(stream().listen(onEvent));
      } on UnsupportedError {
        // Not on this platform.
      }
    }

    listen(() => _peripheralManager.stateChanged, (_) => refresh());
    listen(() => _centralManager.stateChanged, (_) => refresh());
    listen(() => _peripheralManager.characteristicReadRequested, _onRead);
    listen(() => _peripheralManager.characteristicWriteRequested, _onWrite);
    listen(() => _peripheralManager.connectionStateChanged, (e) {
      if (e.state == ConnectionState.disconnected) _centralGone.add('${e.central.uuid}');
    });
    listen(() => _centralManager.discovered, (e) {
      final id = '${e.peripheral.uuid}';
      _peripherals[id] = e.peripheral;
      final a = e.advertisement;
      _discovered.add(
        BleDiscovery(
          id: id,
          rssi: e.rssi,
          sidekick: a.serviceUUIDs.contains(bleServiceUuid) || a.name == bleAdvertisedName,
          name: a.name,
        ),
      );
    });
    listen(() => _centralManager.characteristicNotified, (e) {
      if (e.characteristic.uuid == bleTxUuid) _notified.add(('${e.peripheral.uuid}', e.value));
    });
    listen(() => _centralManager.connectionStateChanged, (e) {
      if (e.state != ConnectionState.disconnected) return;
      final id = '${e.peripheral.uuid}';
      _gatt.remove(id);
      if (_open.remove(id)) _disconnected.add(id);
    });
    await refresh();
  }

  @override
  Future<void> refresh() async {
    var changed = false;
    try {
      final c = _centralManager.state;
      changed |= c != _central;
      _central = c;
    } catch (_) {}
    try {
      final p = _peripheralManager.state;
      changed |= p != _peripheral;
      _peripheral = p;
    } catch (_) {}
    if (changed) _state.add(null);
  }

  @override
  Future<void> advertise() async {
    await _peripheralManager.removeAllServices();
    await _peripheralManager.addService(
      GATTService(
        uuid: bleServiceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [_infoCharacteristic, _rx, _tx],
      ),
    );
    // On Windows adding the service already advertises it (discoverable
    // and connectable); its general advertiser refuses service ids ("The
    // parameter is incorrect").
    if (Platform.isWindows) return;
    // Just the service id: advertisements are tiny (31 bytes), and a name
    // here would rename an Android phone's Bluetooth. Names come from info.
    await _peripheralManager.startAdvertising(Advertisement(serviceUUIDs: [bleServiceUuid]));
  }

  @override
  Future<void> stopAdvertising() => _peripheralManager.stopAdvertising();

  @override
  Future<void> startScan({required bool filtered}) =>
      _centralManager.startDiscovery(serviceUUIDs: filtered ? [bleServiceUuid] : null);

  @override
  Future<void> stopScan() => _centralManager.stopDiscovery();

  Peripheral _peripheralFor(String id) {
    final p = _peripherals[id];
    if (p == null) throw StateError('That device is out of range');
    return p;
  }

  Future<_Gatt> _discover(String id) async {
    final existing = _gatt[id];
    if (existing != null) return existing;
    final peripheral = _peripheralFor(id);
    final services = await _centralManager.discoverGATT(peripheral);
    final service = services.where((s) => s.uuid == bleServiceUuid).firstOrNull;
    if (service == null) throw StateError('it has no Sidekick service');
    GATTCharacteristic find(UUID uuid) {
      final c = service.characteristics.where((c) => c.uuid == uuid).firstOrNull;
      if (c == null) throw StateError('it has an old Sidekick service');
      return c;
    }

    return _gatt[id] = _Gatt(find(bleInfoUuid), find(bleRxUuid), find(bleTxUuid));
  }

  @override
  Future<Uint8List> identify(String id) async {
    final peripheral = _peripheralFor(id);
    if (_open.contains(id)) return readInfo(id);
    try {
      await _centralManager.connect(peripheral);
      final gatt = await _discover(id);
      return await _centralManager.readCharacteristic(peripheral, gatt.info);
    } finally {
      // Don't hold a connection just for a name; phones allow only a few.
      if (!_open.contains(id)) {
        _gatt.remove(id);
        try {
          await _centralManager.disconnect(peripheral);
        } catch (_) {}
      }
    }
  }

  @override
  Future<int> open(String id) async {
    final peripheral = _peripheralFor(id);
    _open.add(id);
    try {
      await _centralManager.connect(peripheral);
      try {
        await _centralManager.requestMTU(peripheral, mtu: 517);
      } catch (_) {
        // Only Android lets apps ask; Windows negotiates by itself.
      }
      final gatt = await _discover(id);
      await _centralManager.setCharacteristicNotifyState(peripheral, gatt.tx, state: true);
      try {
        // One packet (MTU - 3), so writes never turn into long writes.
        return (await _centralManager.getMaximumWriteLength(
          peripheral,
          type: GATTCharacteristicWriteType.withoutResponse,
        )).clamp(20, 512);
      } catch (_) {
        return 20;
      }
    } catch (_) {
      _open.remove(id);
      _gatt.remove(id);
      rethrow;
    }
  }

  @override
  Future<Uint8List> readInfo(String id) async =>
      _centralManager.readCharacteristic(_peripheralFor(id), (await _discover(id)).info);

  @override
  Future<void> write(String id, Uint8List chunk) async => _centralManager.writeCharacteristic(
    _peripheralFor(id),
    (await _discover(id)).rx,
    value: chunk,
    // With response: slower, but nothing gets dropped when buffers fill.
    type: GATTCharacteristicWriteType.withResponse,
  );

  @override
  Future<void> close(String id) async {
    _open.remove(id);
    _gatt.remove(id);
    final p = _peripherals[id];
    if (p != null) await _centralManager.disconnect(p);
  }

  Future<void> _onRead(GATTCharacteristicReadRequestedEventArgs e) async {
    try {
      if (e.characteristic.uuid != bleInfoUuid) {
        await _peripheralManager.respondReadRequestWithError(e.request, error: GATTError.readNotPermitted);
        return;
      }
      final value = _info();
      final offset = e.request.offset.clamp(0, value.length);
      await _peripheralManager.respondReadRequestWithValue(e.request, value: Uint8List.sublistView(value, offset));
    } catch (_) {}
  }

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
    final id = '${e.central.uuid}';
    _centrals[id] = e.central;
    _written.add((id, e.request.value));
  }

  @override
  Future<void> notify(String central, Uint8List chunk) {
    final c = _centrals[central];
    if (c == null) throw StateError("That device isn't listening");
    return _peripheralManager.notifyCharacteristic(c, _tx, value: chunk);
  }

  @override
  Future<int> maxNotify(String central) async {
    final c = _centrals[central];
    if (c == null) return 20;
    try {
      return (await _peripheralManager.getMaximumNotifyLength(c)).clamp(20, 512);
    } catch (_) {
      return 20;
    }
  }

  @override
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

  @override
  Future<void> openBluetoothSettings() async {
    if (Platform.isWindows) await Process.start('explorer.exe', ['ms-settings:bluetooth']);
  }

  @override
  Future<void> stop() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    for (final id in _open.toList()) {
      try {
        await close(id);
      } catch (_) {}
    }
    // Windows advertises the service itself until it's removed.
    for (final step in [
      _peripheralManager.stopAdvertising,
      _peripheralManager.removeAllServices,
      _centralManager.stopDiscovery,
    ]) {
      try {
        await step();
      } catch (_) {}
    }
  }
}

class _Gatt {
  _Gatt(this.info, this.rx, this.tx);
  final GATTCharacteristic info;
  final GATTCharacteristic rx;
  final GATTCharacteristic tx;
}

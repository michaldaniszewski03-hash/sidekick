import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sidekick/core/ble_backend.dart';
import 'package:sidekick/core/bluetooth.dart';
import 'package:sidekick/core/client.dart';
import 'package:sidekick/core/crypto.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/core/trust.dart';
import 'package:sidekick/platform/files.dart';
import 'package:sidekick/platform/input.dart';
import 'package:sidekick/platform/media.dart';

/// The air between fake radios: who's advertising, and packet delivery.
class FakeAir {
  final Map<String, FakeBackend> radios = {};
  final Set<String> advertising = {};
}

/// A [BleBackend] in memory. Packets are tiny (like the smallest Bluetooth
/// MTU) and arrive asynchronously, like on a real radio.
class FakeBackend implements BleBackend {
  FakeBackend(this.air, this.id, {this.packet = 20}) {
    air.radios[id] = this;
  }

  final FakeAir air;
  final String id;
  final int packet;
  late Uint8List Function() _info;
  bool _scanning = false;
  final Set<String> _open = {};
  final List<String> calls = [];

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

  @override
  Future<void> start({required Uint8List Function() info}) async {
    _info = info;
    // Powers on a moment later, like CoreBluetooth.
    Timer(const Duration(milliseconds: 5), () {
      centralState = BleRadio.on;
      peripheralState = BleRadio.on;
      _state.add(null);
    });
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> advertise() async {
    if (peripheralState != BleRadio.on) throw StateError("Bluetooth isn't on");
    air.advertising.add(id);
  }

  @override
  Future<void> stopAdvertising() async => air.advertising.remove(id);

  @override
  Future<void> startScan({required bool filtered}) async {
    calls.add('scan ${filtered ? 'filtered' : 'all'}');
    _scanning = true;
    Timer(const Duration(milliseconds: 10), () {
      if (!_scanning) return;
      // Some other gadget that isn't Sidekick.
      if (!filtered) _discovered.add(const BleDiscovery(id: 'headphones', rssi: -70, sidekick: false));
      // An Apple Watch whose background bitmask happens to match Sidekick's
      // bit, louder than the real thing.
      _discovered.add(const BleDiscovery(id: 'watch', rssi: -30, sidekick: true, strong: false));
      for (final other in air.advertising.where((a) => a != id)) {
        _discovered.add(BleDiscovery(id: other, rssi: -50, sidekick: true, name: filtered ? null : 'Sidekick'));
      }
    });
  }

  @override
  Future<void> stopScan() async => _scanning = false;

  FakeBackend _peer(String other) {
    if (!air.advertising.contains(other)) throw StateError('That device is out of range');
    return air.radios[other]!;
  }

  @override
  Future<Uint8List> identify(String other) async {
    calls.add('identify $other');
    // Connecting takes a moment.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (other == 'watch') throw StateError('It has no Sidekick service');
    return _peer(other)._info();
  }

  @override
  Future<int> open(String other) async {
    _peer(other);
    _open.add(other);
    return packet;
  }

  @override
  Future<Uint8List> readInfo(String other) async => _peer(other)._info();

  @override
  Future<void> write(String other, Uint8List chunk) async {
    if (chunk.length > packet) throw StateError('A write longer than one packet: ${chunk.length}');
    final peer = _peer(other);
    await Future<void>.delayed(Duration.zero);
    peer._written.add((id, chunk));
  }

  @override
  Future<void> close(String other) async => _open.remove(other);

  @override
  Future<void> notify(String central, Uint8List chunk) async {
    if (chunk.length > packet) throw StateError('A notification longer than one packet: ${chunk.length}');
    final peer = air.radios[central]!;
    await Future<void>.delayed(Duration.zero);
    peer._notified.add((id, chunk));
  }

  @override
  Future<int> maxNotify(String central) async {
    // Takes a moment, so request chunks arriving meanwhile must wait their turn.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return packet;
  }

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> openBluetoothSettings() async {}

  @override
  Future<void> stop() async => air.advertising.remove(id);
}

void main() {
  late Directory home;
  final air = FakeAir();

  SidekickServer server(String id, String name, DevicePlatform platform) => SidekickServer(
    identity: Identity.generate(),
    self: () => DeviceInfo(id: id, name: name, platform: platform, port: sidekickPort),
    trust: TrustStore(),
    files: FileService(home: home.path),
    media: UnsupportedMediaController(),
    input: UnsupportedInputInjector(),
    receiveDir: () async => p.join(home.path, 'Received'),
  );

  setUp(() async => home = await Directory.systemTemp.createTemp('sidekick_bt'));
  tearDown(() => home.delete(recursive: true));

  test('an iPhone and a Mac find each other and talk, in one-packet chunks', () async {
    final macId = newDeviceId(), phoneId = newDeviceId();
    final macServer = server(macId, 'MacBook', DevicePlatform.macos);
    final phoneServer = server(phoneId, 'iPhone 15', DevicePlatform.ios);
    final macRadio = FakeBackend(air, 'mac-radio');
    final phoneRadio = FakeBackend(air, 'phone-radio');
    final mac = BluetoothService(self: () => macServer.self(), server: macServer, backend: macRadio);
    final phone = BluetoothService(self: () => phoneServer.self(), server: phoneServer, backend: phoneRadio);

    await mac.start();
    await phone.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(mac.status, BluetoothStatus.on);
    expect(mac.advertising, isTrue, reason: 'advertises once the radio is on');
    expect(phone.advertising, isTrue);

    final found = phone.found.first;
    await phone.scan(duration: const Duration(milliseconds: 50));
    final sighting = await found.timeout(const Duration(seconds: 2));
    expect(sighting.info.id, macId);
    expect(sighting.info.name, 'MacBook');
    expect(sighting.bleId, 'mac-radio');
    expect(phone.candidates['mac-radio']?.info?.id, macId);
    // The look-alike was checked quietly and isn't listed.
    expect(phone.candidates['watch']?.error, isNotNull);
    expect(phone.visibleCandidates.map((c) => c.bleId), ['mac-radio']);

    // Both kinds of scan find it; an unfiltered one also counts other gadgets.
    await phone.scan(duration: const Duration(milliseconds: 50));
    expect(phoneRadio.calls.where((c) => c.startsWith('scan')), ['scan all', 'scan filtered']);
    expect(phone.lastDevicesAround, 3);
    expect(phoneRadio.calls.where((c) => c.startsWith('identify')).toSet(), {
      'identify mac-radio',
      'identify watch',
    }, reason: 'each asked once');
    expect(phoneRadio.calls.where((c) => c == 'identify mac-radio'), hasLength(1));

    // Requests and responses over 20-byte packets, several at once.
    final client = PeerClient.bluetooth(phone.clientFor(sighting.bleId));
    final infos = await Future.wait([client.info(), client.info(), client.info()]);
    expect(infos.map((i) => i.id), [macId, macId, macId]);

    // Pairing over Bluetooth starts: the Mac shows a PIN.
    final requested = macServer.events.where((e) => e is PairRequested).cast<PairRequested>().first;
    await client.requestPairing(phoneServer.self(), myFingerprint: Identity.generate().fingerprint);
    expect((await requested).request.pin, hasLength(6));

    await phone.stop();
    await mac.stop();
  });

  test('a device that is gone shows why, and Retry asks again', () async {
    final pcServer = server(newDeviceId(), 'PC', DevicePlatform.windows);
    final pcRadio = FakeBackend(air, 'pc-radio');
    final pc = BluetoothService(self: () => pcServer.self(), server: pcServer, backend: pcRadio);
    await pc.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Heard, then gone before its name could be read.
    final ghostId = newDeviceId();
    final ghostRadio = FakeBackend(air, 'ghost');
    await ghostRadio.start(
      info: () => Uint8List.fromList(
        utf8.encode(
          jsonEncode(DeviceInfo(id: ghostId, name: 'Pixel', platform: DevicePlatform.android, port: 0).toJson()),
        ),
      ),
    );
    air.advertising.add('ghost');
    final scan = pc.scan(duration: const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 12));
    air.advertising.remove('ghost');
    await scan;
    final ghost = pc.candidates['ghost']!;
    expect(ghost.info, isNull);
    expect(ghost.error, contains('out of range'));

    // Back in range: Retry reads its name.
    air.advertising.add('ghost');
    final found = pc.found.first;
    pc.retry('ghost');
    expect((await found.timeout(const Duration(seconds: 2))).info.name, 'Pixel');
    expect(ghost.error, isNull);
    await pc.stop();
  });
}

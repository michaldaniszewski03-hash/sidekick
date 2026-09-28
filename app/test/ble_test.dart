import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sidekick/core/ble_protocol.dart';
import 'package:sidekick/core/client.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/core/trust.dart';
import 'package:sidekick/platform/files.dart';
import 'package:sidekick/platform/input.dart';
import 'package:sidekick/platform/media.dart';

/// Wires a [BleRpcClient] to a server's [BleRequestDispatcher] through an
/// in-memory "radio" with tiny packets, like the smallest Bluetooth MTU.
PeerClient bluetoothClient(SidekickServer server, {String? token, int mtu = 23}) {
  final toClient = StreamController<Uint8List>();
  final dispatcher = BleRequestDispatcher(server.handleBle);
  final rpc = BleRpcClient(
    chunkSize: () async => mtu - 3,
    incoming: toClient.stream,
    send: (chunk) => dispatcher.onChunk('central-1', chunk, maxChunk: mtu - 3, sendChunk: (c) async => toClient.add(c)),
  );
  return PeerClient.bluetooth(rpc, token: token);
}

void main() {
  group('codec', () {
    test('round-trips header and body across many chunks', () {
      final body = Uint8List.fromList(List.generate(1000, (i) => i % 251));
      final chunks = chunkMessage(7, encodeMessage({'method': 'GET', 'path': '/x'}, body), 20);
      expect(chunks.length, greaterThan(40));
      expect(chunks.every((c) => c.length <= 20), isTrue);
      final r = BleReassembler();
      BleMessage? msg;
      for (final c in chunks) {
        msg = r.add(c);
      }
      expect(msg!.id, 7);
      expect(msg.header['path'], '/x');
      expect(msg.body, body);
    });

    test('keeps interleaved messages apart', () {
      final a = chunkMessage(1, encodeMessage({'n': 'a'}, List.filled(50, 1)), 16);
      final b = chunkMessage(2, encodeMessage({'n': 'b'}, List.filled(50, 2)), 16);
      final r = BleReassembler();
      final done = <BleMessage>[];
      for (var i = 0; i < a.length || i < b.length; i++) {
        if (i < a.length) done.addAll([?r.add(a[i])]);
        if (i < b.length) done.addAll([?r.add(b[i])]);
      }
      expect(done.map((m) => m.header['n']), containsAll(['a', 'b']));
      expect(done.firstWhere((m) => m.id == 2).body.every((x) => x == 2), isTrue);
    });

    test('empty body and garbage', () {
      final r = BleReassembler();
      final msg = r.add(chunkMessage(3, encodeMessage({'ok': true}), 200).single)!;
      expect(msg.body, isEmpty);
      expect(() => r.add(Uint8List.fromList([1, 0])), throwsFormatException);
      expect(() => r.add(Uint8List.fromList([1, 0, 9, 0, 0, 0, 99])), throwsFormatException);
    });
  });

  group('Sidekick over Bluetooth', () {
    late Directory home;
    late SidekickServer pc;
    final pcId = newDeviceId();
    final trust = TrustStore();

    setUp(() async {
      home = await Directory.systemTemp.createTemp('sidekick_ble');
      pc = SidekickServer(
        self: () => DeviceInfo(id: pcId, name: 'PC', platform: DevicePlatform.windows, port: sidekickPort),
        trust: trust,
        files: FileService(home: home.path),
        media: UnsupportedMediaController(),
        input: UnsupportedInputInjector(),
        receiveDir: () async => p.join(home.path, 'Received'),
      );
    });

    tearDown(() => home.delete(recursive: true));

    test('pair, browse, upload, download and media', () async {
      final anon = bluetoothClient(pc);
      expect((await anon.info()).id, pcId);
      expect(() => anon.roots(), throwsA(isA<SidekickException>().having((e) => e.status, 'status', 401)));

      final phone = DeviceInfo(id: newDeviceId(), name: 'Phone', platform: DevicePlatform.android, port: 0);
      final requested = pc.events.where((e) => e is PairRequested).cast<PairRequested>().first;
      await anon.requestPairing(phone);
      final pin = (await requested).request.pin;
      final paired = await anon.confirmPairing(phone.id, pin);
      expect(paired.device.lastAddress, isNull, reason: 'no IP over Bluetooth');

      final client = bluetoothClient(pc, token: paired.device.token, mtu: 185);
      File(p.join(home.path, 'hello.txt')).writeAsStringSync('hi over bluetooth');
      final listing = await client.list(home.path);
      expect(listing.map((e) => e.name), contains('hello.txt'));

      final local = File(p.join(home.path, 'photo.jpg'))..writeAsBytesSync(List.generate(20000, (i) => i % 256));
      final saved = await client.upload(local);
      expect(File(saved).readAsBytesSync(), local.readAsBytesSync());

      final dest = File(p.join(home.path, 'copy.txt'));
      await client.download(p.join(home.path, 'hello.txt'), dest);
      expect(dest.readAsStringSync(), 'hi over bluetooth');

      expect((await client.mediaStatus()).available, isFalse);
      expect(() => client.openInput(), throwsA(isA<SidekickException>()));
    });
  });
}

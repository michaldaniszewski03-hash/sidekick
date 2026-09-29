import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sidekick/core/ble_protocol.dart';
import 'package:sidekick/core/client.dart';
import 'package:sidekick/core/crypto.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/core/trust.dart';
import 'package:sidekick/platform/files.dart';
import 'package:sidekick/platform/hotspot.dart';
import 'package:sidekick/platform/input.dart';
import 'package:sidekick/platform/media.dart';

/// Wires a [BleRpcClient] to a server's [BleRequestDispatcher] through an
/// in-memory "radio" with tiny packets, like the smallest Bluetooth MTU.
PeerClient bluetoothClient(SidekickServer server, {String? token, BleSeal? seal, int mtu = 23}) {
  final toClient = StreamController<Uint8List>();
  final dispatcher = BleRequestDispatcher(server.handleBle, keyFor: server.bleKeyFor, onReceiving: server.bleReceiving);
  final rpc = BleRpcClient(
    chunkSize: () async => mtu - 3,
    incoming: toClient.stream,
    send: (chunk) => dispatcher.onChunk('central-1', chunk, maxChunk: mtu - 3, sendChunk: (c) async => toClient.add(c)),
  );
  return PeerClient.bluetooth(rpc, token: token, seal: seal);
}

/// Pretends to be a phone that opens hotspots and a PC that joins them.
class FakeLink extends DirectLink {
  final events = <String>[];
  @override
  bool get canHost => true;
  @override
  bool get canJoin => true;
  @override
  Future<HotspotCredentials> host() async {
    events.add('host');
    return const HotspotCredentials(ssid: 'DIRECT-sk', passphrase: 'secret123', addresses: ['192.168.49.1']);
  }

  @override
  Future<List<String>> join(HotspotCredentials c) async {
    events.add('join ${c.ssid} ${c.passphrase}');
    return ['192.168.49.20'];
  }

  @override
  Future<void> stopHosting() async => events.add('stop');
  @override
  Future<void> leave() async => events.add('leave');
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

  test('sealed requests cannot be replayed', () async {
    final key = randomBytes(32);
    final sealedBy = <Object?>[];
    final dispatcher = BleRequestDispatcher((m) async {
      sealedBy.add(m.header['sealedBy']);
      return BleResponse(200, const {}, Uint8List(0));
    }, keyFor: (id) => id == 'peer' ? key : null);
    final sent = <Uint8List>[];
    final replies = StreamController<Uint8List>();
    final rpc = BleRpcClient(
      chunkSize: () async => 100,
      incoming: replies.stream,
      send: (chunk) async {
        sent.add(chunk);
        await dispatcher.onChunk('c', chunk, maxChunk: 100, sendChunk: (c) async => replies.add(c));
      },
    );
    final res = await rpc.request(
      'GET',
      '/x',
      seal: BleSeal(senderId: 'peer', key: key),
    );
    expect(res.status, 200);
    expect(sealedBy, ['peer']);
    // Feed the exact same bytes again: refused, handler not run.
    final echoes = <Uint8List>[];
    for (final c in List.of(sent)) {
      await dispatcher.onChunk('c', c, maxChunk: 100, sendChunk: (c) async => echoes.add(c));
    }
    expect(sealedBy, ['peer']);
    final reply = BleReassembler();
    BleMessage? refused;
    for (final c in echoes) {
      refused = reply.add(c) ?? refused;
    }
    // The refusal is sealed too (the key was right, only the nonce reused).
    expect(refused!.header['sealed'], isTrue);
    final inner = decodeMessage(
      refused.id,
      unseal(key, refused.body, aad: utf8.encode('sidekick-ble res ${refused.id}')),
    );
    expect(inner.header['status'], 401);
    // Nobody can pretend a plain message was sealed.
    await dispatcher.onChunk(
      'c',
      chunkMessage(9, encodeMessage({'method': 'GET', 'path': '/x', 'sealedBy': 'peer'}), 100).single,
      maxChunk: 100,
      sendChunk: (_) async {},
    );
    expect(sealedBy, ['peer', null]);
    await rpc.close();
  });

  group('Sidekick over Bluetooth', () {
    late Directory home;
    late SidekickServer pc;
    final pcId = newDeviceId();
    final trust = TrustStore();
    final pcIdentity = Identity.generate();
    final phoneIdentity = Identity.generate();

    setUp(() async {
      home = await Directory.systemTemp.createTemp('sidekick_ble');
      pc = SidekickServer(
        identity: pcIdentity,
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
      final target = await anon.requestPairing(phone, myFingerprint: phoneIdentity.fingerprint);
      final pin = (await requested).request.pin;
      final paired = await anon.confirmPairing(
        myId: phone.id,
        myFingerprint: phoneIdentity.fingerprint,
        target: target,
        pin: pin,
      );
      expect(paired.device.lastAddress, isNull, reason: 'no IP over Bluetooth');
      expect(paired.device.fingerprint, pcIdentity.fingerprint);

      // Paired traffic must be sealed: the token alone isn't enough.
      final unsealed = bluetoothClient(pc, token: paired.device.token);
      await expectLater(unsealed.roots(), throwsA(isA<SidekickException>().having((e) => e.status, 'status', 401)));
      // Sealed with the wrong key: refused too.
      final forged = bluetoothClient(
        pc,
        token: paired.device.token,
        seal: BleSeal(senderId: phone.id, key: randomBytes(32)),
      );
      await expectLater(forged.roots(), throwsA(isA<SidekickException>()));

      final seal = BleSeal(senderId: phone.id, key: base64.decode(paired.key));
      final client = bluetoothClient(pc, token: paired.device.token, seal: seal, mtu: 185);
      File(p.join(home.path, 'hello.txt')).writeAsStringSync('hi over bluetooth');
      final listing = await client.list(home.path);
      expect(listing.map((e) => e.name), contains('hello.txt'));

      final local = File(p.join(home.path, 'photo.jpg'))..writeAsBytesSync(List.generate(20000, (i) => i % 256));
      final received = pc.events.where((e) => e is FileReceived).cast<FileReceived>().first;
      // Asking first works over Bluetooth too.
      final offered = pc.events.where((e) => e is TransferOffered).cast<TransferOffered>().first;
      final reply = client.offerFiles('ble-offer', [('photo.jpg', 20000)]);
      final offer = (await offered).offer..accept();
      final seen = offer.progress.toList();
      var sent = 0;
      final saved = await client.upload(local, ticket: (await reply).ticket, onProgress: (d, _) => sent = d);
      expect(sent, 20000);
      // The receiver's progress moves as packets arrive, not only at the end.
      final steps = await seen;
      expect(steps.where((b) => b > 0 && b < 20000).length, greaterThan(10));
      expect(steps.last, 20000);
      expect(client.lastSecurity?.bluetooth, isTrue, reason: 'the reply decrypted with the pairing key');
      expect((await received).security.bluetooth, isTrue);
      expect(anon.lastSecurity, isNull, reason: 'pairing requests are not sealed');
      expect(File(saved).readAsBytesSync(), local.readAsBytesSync());

      final dest = File(p.join(home.path, 'copy.txt'));
      await client.download(p.join(home.path, 'hello.txt'), dest);
      expect(dest.readAsStringSync(), 'hi over bluetooth');

      expect((await client.mediaStatus()).available, isFalse);
      expect(() => client.openInput(), throwsA(isA<SidekickException>()));
    });

    test('direct link: hotspot and join only over Bluetooth, only for paired devices', () async {
      final link = FakeLink();
      final phone = SidekickServer(
        identity: phoneIdentity,
        self: () => DeviceInfo(id: pcId, name: 'Phone', platform: DevicePlatform.android, port: sidekickPort),
        trust: trust,
        files: FileService(home: home.path),
        media: UnsupportedMediaController(),
        input: UnsupportedInputInjector(),
        receiveDir: () async => home.path,
        link: link,
      );
      final token = newToken();
      final key = randomBytes(32);
      final peerId = newDeviceId();
      trust.add(
        TrustedPeer(
          id: peerId,
          name: 'PC',
          platform: DevicePlatform.windows,
          token: token,
          fingerprint: pcIdentity.fingerprint,
          key: base64.encode(key),
        ),
      );

      expect(() => bluetoothClient(phone).startHotspot(), throwsA(isA<SidekickException>()));

      final client = bluetoothClient(
        phone,
        token: token,
        seal: BleSeal(senderId: peerId, key: key),
      );
      final creds = await client.startHotspot();
      expect(creds.ssid, 'DIRECT-sk');
      expect(creds.addresses, ['192.168.49.1']);
      expect(await client.joinHotspot(creds), ['192.168.49.20']);
      expect(link.events, ['host', 'join DIRECT-sk secret123']);

      await client.releaseLink();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(link.events, containsAll(['stop', 'leave']));

      // On a shared network there's nothing to set up.
      await phone.start(port: 0, address: InternetAddress.loopbackIPv4);
      try {
        final wifi = PeerClient(
          host: '127.0.0.1',
          port: phone.port,
          token: token,
          fingerprint: phoneIdentity.fingerprint,
        );
        await expectLater(
          wifi.startHotspot(),
          throwsA(isA<SidekickException>().having((e) => e.status, 'status', 400)),
        );
      } finally {
        await phone.stop();
      }
    });

    test('credentials round-trip', () {
      const c = HotspotCredentials(ssid: 'a"b', passphrase: 'p', security: 'wpa3', addresses: ['1.2.3.4']);
      final back = HotspotCredentials.fromJson(c.toJson());
      expect(
        [back.ssid, back.passphrase, back.security, back.addresses],
        [
          'a"b',
          'p',
          'wpa3',
          ['1.2.3.4'],
        ],
      );
    });
  });
}

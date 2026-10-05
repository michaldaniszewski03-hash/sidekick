import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sidekick/core/client.dart';
import 'package:sidekick/core/crypto.dart';
import 'package:sidekick/core/mirror.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/core/trust.dart';
import 'package:sidekick/platform/files.dart';
import 'package:sidekick/platform/input.dart';
import 'package:sidekick/platform/screen_source.dart';

/// A tile of one colour.
MirrorTile solid(int x, int y, int w, int h, int b, int g, int r) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < px.length; i += 4) {
    px[i] = b;
    px[i + 1] = g;
    px[i + 2] = r;
    px[i + 3] = 255;
  }
  return MirrorTile(x, y, w, h, px);
}

/// A screen that plays back [packets], then nothing changes.
class FakeScreen implements ScreenSource {
  FakeScreen(this.packets);
  final List<MirrorPacket> packets;
  bool running = false;
  bool? sharp;
  var _next = 0;
  int keyframes = 0;

  @override
  bool get supported => true;

  @override
  String get startHint => 'Tap Start on the phone';

  @override
  Future<void> start({required bool sharp, required String viewer}) async {
    running = true;
    this.sharp = sharp;
  }

  @override
  Future<void> setSharp(bool sharp) async => this.sharp = sharp;

  @override
  Future<Uint8List?> frame() async {
    if (!running) return null;
    if (_next < packets.length) return packets[_next++].toBytes();
    final last = packets.last;
    return MirrorPacket(width: last.width, height: last.height, cursorX: 5, cursorY: 6, tiles: []).toBytes();
  }

  @override
  Future<void> keyframe() async => keyframes++;

  @override
  Future<void> stop() async => running = false;
}

class NoInput implements InputInjector {
  @override
  bool get supported => false;
  @override
  void moveBy(int dx, int dy) {}
  @override
  void button(MouseButton button, {required bool down}) {}
  @override
  void click(MouseButton button, {int count = 1}) {}
  @override
  void scroll({int dx = 0, int dy = 0}) {}
  @override
  void key(String key, {List<String> modifiers = const []}) {}
  @override
  void text(String text) {}
}

void main() {
  group('packets', () {
    test('round trip', () {
      final packet = MirrorPacket(
        width: 100,
        height: 50,
        cursorX: 10,
        cursorY: -1,
        keyframe: true,
        tiles: [solid(0, 0, 64, 50, 1, 2, 3), solid(64, 10, 36, 20, 9, 8, 7)],
      );
      final bytes = packet.toBytes();
      expect(MirrorPacket.tileCountOf(bytes), 2);
      final back = MirrorPacket.parse(bytes);
      expect((back.width, back.height, back.cursorX, back.cursorY, back.keyframe), (100, 50, 10, -1, true));
      expect(back.tiles.map((t) => (t.x, t.y, t.w, t.h)), [(0, 0, 64, 50), (64, 10, 36, 20)]);
      expect(back.tiles[1].pixels, packet.tiles[1].pixels);
      expect(back.hasCursor, isFalse);
    });

    test('damaged packets are refused', () {
      final good = MirrorPacket(
        width: 8,
        height: 8,
        cursorX: 0,
        cursorY: 0,
        tiles: [solid(0, 0, 8, 8, 0, 0, 0)],
      ).toBytes();
      expect(() => MirrorPacket.parse(Uint8List.sublistView(good, 0, 40)), throwsFormatException);
      expect(() => MirrorPacket.parse(Uint8List(16)), throwsFormatException);
      final outside = MirrorPacket(width: 8, height: 8, cursorX: 0, cursorY: 0, tiles: [solid(4, 4, 8, 8, 0, 0, 0)]);
      expect(() => MirrorPacket.parse(outside.toBytes()), throwsFormatException);
    });
  });

  test('Android RGBA and turned iPhone pictures say so', () {
    final packet = MirrorPacket(
      width: 4,
      height: 2,
      cursorX: -1,
      cursorY: -1,
      rgba: true,
      turns: 3,
      keyframe: true,
      tiles: [solid(0, 0, 4, 2, 1, 2, 3)],
    );
    final back = MirrorPacket.parse(packet.toBytes());
    expect((back.rgba, back.turns, back.keyframe), (true, 3, true));
    final canvas = MirrorCanvas()..apply(back);
    expect((canvas.rgba, canvas.turns), (true, 3));
    // Back to BGRA: a new picture.
    canvas.apply(MirrorPacket(width: 4, height: 2, cursorX: -1, cursorY: -1, tiles: []));
    expect((canvas.rgba, canvas.turns, canvas.pixels.every((v) => v == 0)), (false, 0, true));
  });

  test('iPhone: packets come from the broadcast extension over loopback', () async {
    final port = 40000 + DateTime.now().microsecond % 20000;
    final sent = MirrorPacket(width: 8, height: 8, cursorX: -1, cursorY: -1, tiles: [solid(0, 0, 8, 8, 9, 9, 9)]);
    final commands = <String>[];
    // Stands in for SampleHandler.swift: says hello, answers N with a packet.
    final screen = IphoneScreen(
      port: port,
      openPicker: () async {
        final ext = await Socket.connect(InternetAddress.loopbackIPv4, port);
        ext.add('SKB1'.codeUnits);
        ext.listen((data) {
          for (final c in data) {
            commands.add(String.fromCharCode(c));
            if (c == 'N'.codeUnitAt(0)) {
              final bytes = sent.toBytes();
              ext.add((ByteData(4)..setUint32(0, bytes.length, Endian.little)).buffer.asUint8List());
              // In two pieces, as TCP may deliver it.
              ext.add(bytes.sublist(0, 10));
              ext.add(bytes.sublist(10));
            }
            if (c == 'Q'.codeUnitAt(0)) ext.destroy();
          }
        });
      },
    );
    await screen.start(sharp: true, viewer: 'Mac');
    final first = await screen.frame();
    final second = await screen.frame();
    expect(first, sent.toBytes());
    expect(second, sent.toBytes());
    await screen.setSharp(false);
    await screen.stop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(commands, ['S', 'N', 'N', 'F', 'Q']);
  });

  test('the canvas paints tiles in and starts over at a new size', () {
    final canvas = MirrorCanvas()
      ..apply(MirrorPacket(width: 4, height: 2, cursorX: 1, cursorY: 1, tiles: [solid(0, 0, 4, 2, 10, 10, 10)]))
      ..apply(MirrorPacket(width: 4, height: 2, cursorX: 3, cursorY: 0, tiles: [solid(2, 1, 2, 1, 200, 100, 50)]));
    int at(int x, int y) => canvas.pixels[(y * 4 + x) * 4];
    expect([at(0, 0), at(3, 0), at(1, 1), at(2, 1), at(3, 1)], [10, 10, 10, 200, 200]);
    expect((canvas.cursorX, canvas.cursorY), (3, 0));
    canvas.apply(MirrorPacket(width: 2, height: 2, cursorX: -1, cursorY: -1, tiles: []));
    expect((canvas.width, canvas.height, canvas.pixels.every((v) => v == 0)), (2, 2, true));
  });

  test('zlib in the worker isolate round-trips (lossless)', () async {
    final zip = await MirrorZip.start();
    addTearDown(zip.close);
    final data = Uint8List.fromList(List.generate(200000, (i) => (i * 7) % 251));
    final packed = await zip.compress(data);
    expect(packed.length, lessThan(data.length));
    expect(await zip.decompress(packed), data);
  });

  group('over the network', () {
    late Directory tmp;
    late SidekickServer pc;
    late FakeScreen screen;
    late PeerClient viewer;
    var allow = true;
    final asked = <String>[];
    final pcId = newDeviceId();
    final pcIdentity = Identity.generate();
    final pcTrust = TrustStore();

    final frames = [
      MirrorPacket(
        width: 128,
        height: 64,
        cursorX: 1,
        cursorY: 2,
        keyframe: true,
        tiles: [solid(0, 0, 64, 64, 255, 0, 0), solid(64, 0, 64, 64, 0, 255, 0)],
      ),
      MirrorPacket(width: 128, height: 64, cursorX: 3, cursorY: 4, tiles: [solid(32, 16, 16, 16, 0, 0, 255)]),
    ];

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sidekick_mirror');
      screen = FakeScreen(frames);
      allow = true;
      asked.clear();
      pc = SidekickServer(
        identity: pcIdentity,
        self: () => DeviceInfo(id: pcId, name: 'iPhone', platform: DevicePlatform.ios, port: pc.port),
        trust: pcTrust,
        files: FileService(home: tmp.path),
        input: NoInput(),
        receiveDir: () async => p.join(tmp.path, 'Received'),
        screen: screen,
        approveMirror: (peer) async {
          asked.add(peer.name);
          return allow;
        },
      );
      await pc.start(port: 0, address: InternetAddress.loopbackIPv4);
      final token = newToken();
      pcTrust.add(
        TrustedPeer(
          id: 'mac',
          name: 'Mac',
          platform: DevicePlatform.macos,
          token: token,
          fingerprint: Identity.generate().fingerprint,
          key: 'k',
        ),
      );
      viewer = PeerClient(host: '127.0.0.1', port: pc.port, token: token, fingerprint: pcIdentity.fingerprint);
    });

    tearDown(() async {
      await pc.stop();
      await tmp.delete(recursive: true);
    });

    test('the Mac ends up with exactly the phone\'s pixels', () async {
      final started = pc.events.where((e) => e is MirrorSessionChanged).cast<MirrorSessionChanged>().first;
      final stream = await viewer.openMirror(sharp: true);
      final zip = await MirrorZip.start();
      addTearDown(zip.close);
      final canvas = MirrorCanvas();
      final types = <String>[];
      stream.messages.listen((m) => types.add(m.type));
      var withTiles = 0;
      await for (final z in stream.frames) {
        final packet = MirrorPacket.parse(await zip.decompress(z));
        canvas.apply(packet);
        stream.ack();
        if (packet.tiles.isNotEmpty) withTiles++;
        if (withTiles == 2 && packet.tiles.isEmpty) break;
      }
      expect((await started).active, isTrue);
      expect(asked, ['Mac']);
      expect(screen.sharp, isTrue);
      expect(types, containsAllInOrder(['status', 'status', 'started']));
      expect(pc.mirroringTo?.name, 'Mac');

      final expected = MirrorCanvas();
      for (final f in frames) {
        expected.apply(f);
      }
      expect(canvas.pixels, expected.pixels, reason: 'lossless');
      expect((canvas.cursorX, canvas.cursorY), (5, 6));

      final ended = pc.events.where((e) => e is MirrorSessionChanged).cast<MirrorSessionChanged>().first;
      await stream.close();
      expect((await ended.timeout(const Duration(seconds: 3))).active, isFalse);
      expect(screen.running, isFalse, reason: 'capture stops with the viewer');
    });

    test('nothing is shown unless the person holding the phone allows it', () async {
      allow = false;
      final stream = await viewer.openMirror();
      final error = await stream.messages.firstWhere((m) => m.type == 'error');
      expect(error.message, contains("didn't allow"));
      expect(screen.running, isFalse);
      await stream.close();
    });

    test('the Stop button ends it from the phone', () async {
      final stream = await viewer.openMirror();
      await stream.messages.firstWhere((m) => m.type == 'started');
      pc.stopMirroring();
      await stream.frames.drain<void>().timeout(const Duration(seconds: 3));
      expect(screen.running, isFalse);
    });

    test('turned off in Settings: refused with a reason', () async {
      final off = SidekickServer(
        identity: pcIdentity,
        self: () => DeviceInfo(id: pcId, name: 'iPhone', platform: DevicePlatform.ios, port: 0),
        trust: pcTrust,
        files: FileService(home: tmp.path),
        input: NoInput(),
        receiveDir: () async => tmp.path,
        permissions: () => const Permissions(mirror: false),
        screen: screen,
      );
      await off.start(port: 0, address: InternetAddress.loopbackIPv4);
      addTearDown(off.stop);
      final client = PeerClient(
        host: '127.0.0.1',
        port: off.port,
        token: viewer.token,
        fingerprint: pcIdentity.fingerprint,
      );
      await expectLater(client.openMirror(), throwsA(isA<SidekickException>().having((e) => e.status, 'status', 403)));
    });
  });
}

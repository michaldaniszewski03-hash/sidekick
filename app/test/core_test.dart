import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sidekick/core/client.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/core/trust.dart';
import 'package:sidekick/platform/files.dart';
import 'package:sidekick/platform/input.dart';
import 'package:sidekick/platform/media.dart';
import 'package:sidekick/ui/remote_page.dart';

extension<T> on Stream<T> {
  Stream<S> only<S>() => where((e) => e is S).cast<S>();
}

class FakeInput implements InputInjector {
  final log = <String>[];
  @override
  bool get supported => true;
  @override
  void moveBy(int dx, int dy) => log.add('move $dx $dy');
  @override
  void button(MouseButton button, {required bool down}) => log.add('${down ? 'down' : 'up'} ${button.name}');
  @override
  void click(MouseButton button, {int count = 1}) => log.add('click ${button.name} $count');
  @override
  void scroll({int dx = 0, int dy = 0}) => log.add('scroll $dx $dy');
  @override
  void key(String key, {List<String> modifiers = const []}) => log.add('key ${[...modifiers, key].join('+')}');
  @override
  void text(String text) => log.add('text $text');
  @override
  void virtualKey(int vk) => log.add('vk $vk');
}

class FakeMedia implements MediaController {
  final actions = <String>[];
  @override
  bool get supported => true;
  @override
  Future<MediaStatus> status() async => const MediaStatus(
    available: true,
    title: 'Night Drive',
    status: PlaybackStatus.playing,
    position: Duration(seconds: 84),
    duration: Duration(seconds: 252),
    volume: 0.5,
  );
  @override
  Future<void> perform(MediaAction action, {Duration? position, double? volume}) async =>
      actions.add([action.name, if (position != null) position.inSeconds, ?volume].join(' '));
  @override
  Future<void> dispose() async {}
}

/// One simulated device: a server plus what it knows.
class Node {
  Node(this.name, Directory root)
    : id = newDeviceId(),
      home = Directory(p.join(root.path, name))..createSync(recursive: true) {
    server = SidekickServer(
      self: () => DeviceInfo(id: id, name: name, platform: DevicePlatform.windows, port: server.port),
      trust: trust,
      files: FileService(home: home.path),
      media: media,
      input: input,
      receiveDir: () async => p.join(home.path, 'Received'),
      permissions: () => permissions,
    );
  }

  final String id;
  final String name;
  final Directory home;
  final trust = TrustStore();
  final input = FakeInput();
  final media = FakeMedia();
  Permissions permissions = const Permissions();
  late final SidekickServer server;

  DeviceInfo get info => DeviceInfo(id: id, name: name, platform: DevicePlatform.windows, port: server.port);
  PeerClient anonymous() => PeerClient(host: '127.0.0.1', port: server.port);
}

void main() {
  late Directory tmp;
  late Node pc, phone;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sidekick_test');
    pc = Node('pc', tmp);
    phone = Node('phone', tmp);
    await pc.server.start(port: 0, address: InternetAddress.loopbackIPv4);
    await phone.server.start(port: 0, address: InternetAddress.loopbackIPv4);
  });

  tearDown(() async {
    await pc.server.stop();
    await phone.server.stop();
    await tmp.delete(recursive: true);
  });

  /// Phone pairs with the PC using the PIN the PC shows. Returns a client
  /// the phone can use to control the PC.
  Future<PeerClient> pair() async {
    final requested = pc.server.events.only<PairRequested>().first;
    await pc.anonymous().requestPairing(phone.info);
    final pin = (await requested).request.pin;
    final result = await pc.anonymous().confirmPairing(phone.id, pin);
    phone.trust.add(
      TrustedPeer(id: pc.id, name: pc.name, platform: DevicePlatform.windows, token: result.tokenForThem),
    );
    return PeerClient(host: '127.0.0.1', port: pc.server.port, token: result.device.token);
  }

  test('info works without pairing', () async {
    final info = await pc.anonymous().info();
    expect(info.id, pc.id);
    expect(info.name, 'pc');
  });

  test('everything else needs a token', () async {
    expect(() => pc.anonymous().roots(), throwsA(isA<SidekickException>().having((e) => e.status, 'status', 401)));
    final bad = PeerClient(host: '127.0.0.1', port: pc.server.port, token: newToken());
    expect(() => bad.mediaStatus(), throwsA(isA<SidekickException>().having((e) => e.notPaired, 'notPaired', true)));
  });

  test('pairing is mutual', () async {
    final paired = pc.server.events.only<Paired>().first;
    final client = await pair();

    // The phone can use the PC…
    expect((await client.mediaStatus()).title, 'Night Drive');
    // …and the PC got a token that works on the phone.
    final back = (await paired).device;
    expect(back.id, phone.id);
    final reverse = PeerClient(host: '127.0.0.1', port: phone.server.port, token: back.token);
    expect((await reverse.info()).id, phone.id);
    expect((await reverse.roots()), isNotEmpty);
  });

  test('wrong PIN is rejected and the request locks after 5 tries', () async {
    final requested = pc.server.events.only<PairRequested>().first;
    await pc.anonymous().requestPairing(phone.info);
    final pin = (await requested).request.pin;
    final wrong = pin == '000000' ? '111111' : '000000';
    for (var i = 0; i < 5; i++) {
      await expectLater(pc.anonymous().confirmPairing(phone.id, wrong), throwsA(isA<SidekickException>()));
    }
    // Even the right PIN fails now.
    await expectLater(
      pc.anonymous().confirmPairing(phone.id, pin),
      throwsA(isA<SidekickException>().having((e) => e.status, 'status', 410)),
    );
    expect(pc.trust.peers, isEmpty);
  });

  test('repeated pairing requests reuse the open code', () async {
    var shown = 0;
    final sub = pc.server.events.only<PairRequested>().listen((_) => shown++);
    await pc.anonymous().requestPairing(phone.info);
    await pc.anonymous().requestPairing(phone.info);
    await Future<void>.delayed(Duration.zero);
    expect(shown, 1);
    await sub.cancel();
  });

  test('cancelled pairing cannot be confirmed', () async {
    final requested = pc.server.events.only<PairRequested>().first;
    await pc.anonymous().requestPairing(phone.info);
    final pin = (await requested).request.pin;
    pc.server.cancelPairing(phone.id);
    await expectLater(pc.anonymous().confirmPairing(phone.id, pin), throwsA(isA<SidekickException>()));
  });

  test('browse, download and upload files', () async {
    final client = await pair();
    final docs = Directory(p.join(pc.home.path, 'Documents'))..createSync();
    File(p.join(docs.path, 'notes.txt')).writeAsStringSync('hello from the pc');
    Directory(p.join(docs.path, 'Projects')).createSync();

    final roots = await client.roots();
    expect(roots.map((e) => e.name), containsAll(['Documents', 'Home']));

    final listing = await client.list(docs.path);
    expect(listing.map((e) => e.name).toList(), ['Projects', 'notes.txt'], reason: 'folders first');
    expect(listing.last.size, 17);

    final dest = File(p.join(tmp.path, 'notes-copy.txt'));
    var progress = 0;
    await client.download(listing.last.path, dest, onProgress: (d, _) => progress = d);
    expect(dest.readAsStringSync(), 'hello from the pc');
    expect(progress, 17);

    final received = pc.server.events.only<FileReceived>().first;
    final upload = File(p.join(tmp.path, 'photo.jpg'))..writeAsBytesSync(List.filled(300000, 7));
    final saved = await client.upload(upload);
    expect(p.dirname(saved), p.join(pc.home.path, 'Received'));
    expect(File(saved).lengthSync(), 300000);
    expect((await received).from.id, phone.id);

    // Same name again doesn't overwrite.
    final saved2 = await client.upload(upload);
    expect(p.basename(saved2), 'photo (1).jpg');

    // Upload into a folder we browsed to.
    final intoDocs = await client.upload(upload, remoteDir: docs.path);
    expect(p.dirname(intoDocs), docs.path);
    // No partial files left behind.
    expect(docs.listSync().where((e) => e.path.endsWith('.sidekick-part')), isEmpty);
  });

  test('upload names are sanitized', () async {
    final client = await pair();
    final f = File(p.join(tmp.path, 'x'))..writeAsStringSync('x');
    final saved = await client.upload(f, name: r'..\..\Windows\evil:name?.txt');
    expect(p.dirname(saved), p.join(pc.home.path, 'Received'));
    expect(p.basename(saved), 'evil_name_.txt');
  });

  test('media status and actions', () async {
    final client = await pair();
    final status = await client.mediaStatus();
    expect(status.isPlaying, isTrue);
    expect(status.duration, const Duration(seconds: 252));
    await client.media(MediaAction.playPause);
    await client.media(MediaAction.seek, position: const Duration(seconds: 30));
    await client.media(MediaAction.setVolume, volume: 0.25);
    expect(pc.media.actions, ['playPause', 'seek 30', 'setVolume 0.25']);
  });

  test('permissions switch features off', () async {
    final client = await pair();
    pc.permissions = const Permissions(files: false, media: true, input: true);
    expect(() => client.roots(), throwsA(isA<SidekickException>().having((e) => e.status, 'status', 403)));
    expect((await client.mediaStatus()).available, isTrue);
  });

  test('remote input over WebSocket', () async {
    final client = await pair();
    final sessions = pc.server.events.only<RemoteSessionChanged>();
    final opened = sessions.first;
    final session = await client.openInput();
    expect((await opened).active, isTrue);

    final closed = sessions.firstWhere((e) => !e.active);
    session
      ..move(3.6, -2)
      ..click(button: 'right')
      ..scroll(dy: -120)
      ..key('c', modifiers: ['ctrl'])
      ..text('hi');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await session.close();
    await closed;
    expect(pc.input.log, ['move 3 -2', 'click right 1', 'scroll 0 -120', 'key ctrl+c', 'text hi']);
  });

  test('unpairing ends a live remote-control session', () async {
    final client = await pair();
    final session = await client.openInput();
    session.key('a');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    pc.trust.remove(phone.id);
    session.key('b');
    session.key('c');
    await session.closed.timeout(const Duration(seconds: 2));
    expect(pc.input.log, ['key a']);
  });

  test('unpair revokes access on both ends', () async {
    final client = await pair();
    final unpaired = pc.server.events.only<Unpaired>().first;
    await client.unpair();
    expect((await unpaired).peerId, phone.id);
    expect(() => client.roots(), throwsA(isA<SidekickException>()));
  });

  test('input messages are validated', () {
    final input = FakeInput();
    handleInputMessage(input, {'t': 'move', 'dx': 'nope', 'dy': 1e12});
    handleInputMessage(input, {'t': 'click', 'n': 50});
    handleInputMessage(input, {'t': 'key', 'k': 42});
    handleInputMessage(input, {'t': 'text', 's': 'x' * 5000});
    handleInputMessage(input, {'t': 'rm -rf'});
    expect(input.log, ['move 0 100000', 'click left 3']);
  });

  group('helpers', () {
    test('sanitizeFileName', () {
      expect(sanitizeFileName('a/b/c.txt'), 'c.txt');
      expect(sanitizeFileName(r'C:\x\y.png'), 'y.png');
      expect(sanitizeFileName('what?.txt'), 'what_.txt');
      expect(sanitizeFileName('..'), 'file');
      expect(sanitizeFileName('CON.txt'), '_CON.txt');
      expect(sanitizeFileName('trailing. . '), 'trailing');
    });

    test('typingDiff', () {
      expect(typingDiff('', 'h'), (0, 'h'));
      expect(typingDiff('hel', 'hello'), (0, 'lo'));
      expect(typingDiff('hello', 'hell'), (1, ''));
      expect(typingDiff('teh ', 'the '), (3, 'he '), reason: 'autocorrect rewrite');
      expect(typingDiff('abc', ''), (3, ''));
    });

    test('prettyAppName', () {
      expect(prettyAppName('Spotify.exe'), 'Spotify');
      expect(prettyAppName('chrome'), 'Chrome');
      expect(prettyAppName('Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic'), 'Media Player');
      expect(prettyAppName('308046B0AF4A39CB'), '308046B0AF4A39CB');
    });

    test('INPUT struct matches the 64-bit Win32 layout', () {
      expect(inputStructSize, 40);
    });

    test('virtualKeyFor', () {
      expect(virtualKeyFor('a'), 0x41);
      expect(virtualKeyFor('Z'), 0x5A);
      expect(virtualKeyFor('7'), 0x37);
      expect(virtualKeyFor('enter'), 0x0D);
      expect(virtualKeyFor('nope'), isNull);
    });

    test('media status round-trips through JSON', () {
      const s = MediaStatus(
        available: true,
        title: 'T',
        status: PlaybackStatus.paused,
        position: Duration(seconds: 5),
        volume: 0.3,
      );
      final back = MediaStatus.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.title, 'T');
      expect(back.status, PlaybackStatus.paused);
      expect(back.position, const Duration(seconds: 5));
      expect(back.volume, 0.3);
    });
  });
}

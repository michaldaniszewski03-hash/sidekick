import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sidekick/core/client.dart';
import 'package:sidekick/core/crypto.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/core/trust.dart';
import 'package:sidekick/platform/device_name.dart';
import 'package:sidekick/platform/files.dart';
import 'package:sidekick/platform/input.dart';
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
}

/// One simulated device: a server plus what it knows.
class Node {
  Node(this.name, Directory root)
    : id = newDeviceId(),
      home = Directory(p.join(root.path, name))..createSync(recursive: true) {
    server = SidekickServer(
      identity: identity,
      self: () => DeviceInfo(id: id, name: name, platform: DevicePlatform.windows, port: server.port),
      trust: trust,
      files: FileService(home: home.path),
      input: input,
      receiveDir: () async => p.join(home.path, 'Received'),
      permissions: () => permissions,
    );
  }

  final String id;
  final String name;
  final Directory home;
  final identity = Identity.generate();
  final trust = TrustStore();
  final input = FakeInput();
  Permissions permissions = const Permissions();
  late final SidekickServer server;

  DeviceInfo get info => DeviceInfo(id: id, name: name, platform: DevicePlatform.windows, port: server.port);
  PeerClient anonymous() => PeerClient(host: '127.0.0.1', port: server.port);

  /// Asks [other] to show a PIN, as this device.
  Future<PairingTarget> requestFrom(Node other, {String? claim}) =>
      other.anonymous().requestPairing(info, myFingerprint: claim ?? identity.fingerprint);

  Future<({PairedDevice device, String tokenForThem, String key})> confirmWith(
    Node other,
    PairingTarget target,
    String pin, {
    String? claim,
  }) => other.anonymous().confirmPairing(
    myId: id,
    myFingerprint: claim ?? identity.fingerprint,
    target: target,
    pin: pin,
  );
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
    final target = await phone.requestFrom(pc);
    expect(target.fingerprint, pc.identity.fingerprint);
    final pin = (await requested).request.pin;
    final result = await phone.confirmWith(pc, target, pin);
    phone.trust.add(
      TrustedPeer(
        id: pc.id,
        name: pc.name,
        platform: DevicePlatform.windows,
        token: result.tokenForThem,
        fingerprint: pc.identity.fingerprint,
        key: result.key,
      ),
    );
    expect(result.device.fingerprint, pc.identity.fingerprint);
    return PeerClient.forDevice(result.device);
  }

  test('info works without pairing', () async {
    final info = await pc.anonymous().info();
    expect(info.id, pc.id);
    expect(info.name, 'pc');
  });

  test('everything else needs a token', () async {
    expect(() => pc.anonymous().roots(), throwsA(isA<SidekickException>().having((e) => e.status, 'status', 401)));
    final bad = PeerClient(host: '127.0.0.1', port: pc.server.port, token: newToken());
    expect(() => bad.roots(), throwsA(isA<SidekickException>().having((e) => e.notPaired, 'notPaired', true)));
  });

  test('pairing is mutual', () async {
    final paired = pc.server.events.only<Paired>().first;
    final client = await pair();

    // The phone can use the PC…
    expect(await client.roots(), isNotEmpty);
    // …and the PC got a token that works on the phone.
    final back = (await paired).device;
    expect(back.id, phone.id);
    expect(back.fingerprint, phone.identity.fingerprint);
    expect(back.key, phone.trust.byId(pc.id)!.key, reason: 'both sides derived the same key');
    final reverse = PeerClient(
      host: '127.0.0.1',
      port: phone.server.port,
      token: back.token,
      fingerprint: back.fingerprint,
    );
    expect((await reverse.info()).id, phone.id);
    expect((await reverse.roots()), isNotEmpty);
  });

  test('a pinned client refuses a server with another certificate', () async {
    final client = await pair();
    // Something else answering at the PC's address, e.g. an impostor.
    final impostor = PeerClient(
      host: '127.0.0.1',
      port: phone.server.port,
      token: client.token,
      fingerprint: client.fingerprint,
    );
    await expectLater(impostor.info(), throwsA(isA<SidekickException>()));
    expect((await client.info()).id, pc.id);
  });

  test('pairing fails when either certificate was swapped (man in the middle)', () async {
    var requested = pc.server.events.only<PairRequested>().first;
    // The PC was told a different certificate for the phone than the phone has.
    var target = await phone.requestFrom(pc, claim: 'a' * 64);
    var pin = (await requested).request.pin;
    await expectLater(
      phone.confirmWith(pc, target, pin),
      throwsA(isA<SidekickException>().having((e) => e.status, 'status', 403)),
    );

    pc.server.cancelPairing(phone.id);
    requested = pc.server.events.only<PairRequested>().first;
    // The phone saw a different certificate for the PC than the PC has.
    target = await phone.requestFrom(pc);
    pin = (await requested).request.pin;
    await expectLater(
      phone.confirmWith(pc, (device: target.device, fingerprint: 'b' * 64), pin),
      throwsA(isA<SidekickException>()),
    );
    expect(pc.trust.peers, isEmpty);
  });

  test('wrong PIN is rejected and the request locks after 5 tries', () async {
    final requested = pc.server.events.only<PairRequested>().first;
    final target = await phone.requestFrom(pc);
    final pin = (await requested).request.pin;
    final wrong = pin == '000000' ? '111111' : '000000';
    for (var i = 0; i < 5; i++) {
      await expectLater(phone.confirmWith(pc, target, wrong), throwsA(isA<SidekickException>()));
    }
    // Even the right PIN fails now.
    await expectLater(
      phone.confirmWith(pc, target, pin),
      throwsA(isA<SidekickException>().having((e) => e.status, 'status', 410)),
    );
    expect(pc.trust.peers, isEmpty);
  });

  test('repeated pairing requests reuse the open code', () async {
    var shown = 0;
    final sub = pc.server.events.only<PairRequested>().listen((_) => shown++);
    await phone.requestFrom(pc);
    await phone.requestFrom(pc);
    await Future<void>.delayed(Duration.zero);
    expect(shown, 1);
    await sub.cancel();
  });

  test('cancelled pairing cannot be confirmed', () async {
    final requested = pc.server.events.only<PairRequested>().first;
    final target = await phone.requestFrom(pc);
    final pin = (await requested).request.pin;
    pc.server.cancelPairing(phone.id);
    await expectLater(phone.confirmWith(pc, target, pin), throwsA(isA<SidekickException>()));
  });

  /// Offers [files] to the PC and has the PC accept; returns the ticket.
  Future<String> accepted(PeerClient client, List<(String, int)> files) async {
    final offered = pc.server.events.only<TransferOffered>().first;
    final reply = client.offerFiles(newToken().substring(0, 16), files);
    (await offered).offer.accept();
    final answer = await reply;
    expect(answer.accepted, isTrue);
    return answer.ticket!;
  }

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
    final ticket = await accepted(client, [('photo.jpg', 300000), ('photo.jpg', 300000)]);
    final saved = await client.upload(upload, ticket: ticket);
    // The label comes from the connection: the certificate the PC presented.
    expect(client.lastSecurity?.bluetooth, isFalse);
    expect(client.lastSecurity?.certificate, pc.identity.fingerprint);
    expect((await received).security.bluetooth, isFalse);
    expect(p.dirname(saved), p.join(pc.home.path, 'Received'));
    expect(File(saved).lengthSync(), 300000);
    expect((await received).from.id, phone.id);

    // Same name again doesn't overwrite.
    final saved2 = await client.upload(upload, ticket: ticket);
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
    final ticket = await accepted(client, [(r'..\..\Windows\evil:name?.txt', 1)]);
    final saved = await client.upload(f, name: r'..\..\Windows\evil:name?.txt', ticket: ticket);
    expect(p.dirname(saved), p.join(pc.home.path, 'Received'));
    expect(p.basename(saved), 'evil_name_.txt');
  });

  test('sending asks first: accept, decline, cancel, and tickets', () async {
    final client = await pair();
    final f = File(p.join(tmp.path, 'song.mp3'))..writeAsBytesSync(List.filled(5000, 1));

    // No ticket, no file.
    await expectLater(client.upload(f), throwsA(isA<SidekickException>().having((e) => e.status, 'status', 403)));
    expect(Directory(p.join(pc.home.path, 'Received')).existsSync(), isFalse);

    // The PC sees who and what, then declines.
    var offered = pc.server.events.only<TransferOffered>().first;
    var reply = client.offerFiles('offer-1', [('song.mp3', 5000)]);
    final offer = (await offered).offer;
    expect(offer.from.id, phone.id);
    expect(offer.files.single.name, 'song.mp3');
    expect(offer.totalBytes, 5000);
    offer.decline();
    expect((await reply).accepted, isFalse);
    expect((await reply).answer, 'declined');

    // The phone gives up while the PC's prompt is open: it closes.
    offered = pc.server.events.only<TransferOffered>().first;
    reply = client.offerFiles('offer-2', [('song.mp3', 5000)]);
    final waiting = (await offered).offer;
    await client.cancelOffer('offer-2');
    expect(await waiting.answer, OfferAnswer.cancelled);
    expect((await reply).answer, 'cancelled');

    // Accepted: the PC follows the progress, and the ticket covers exactly
    // the files offered.
    offered = pc.server.events.only<TransferOffered>().first;
    reply = client.offerFiles('offer-3', [('song.mp3', 5000)]);
    final accepted = (await offered).offer..accept();
    final progress = accepted.progress.toList();
    final ticket = (await reply).ticket!;
    await client.upload(f, ticket: ticket);
    expect((await progress).last, 5000);
    expect(accepted.complete, isTrue);
    await expectLater(client.upload(f, ticket: ticket), throwsA(isA<SidekickException>()));

    // Another device can't use someone else's ticket.
    offered = pc.server.events.only<TransferOffered>().first;
    reply = client.offerFiles('offer-4', [('song.mp3', 5000)]);
    (await offered).offer.accept();
    final stolen = (await reply).ticket!;
    final other = Node('laptop', tmp);
    await other.server.start(port: 0, address: InternetAddress.loopbackIPv4);
    final requested = pc.server.events.only<PairRequested>().first;
    final target = await other.requestFrom(pc);
    final paired = await other.confirmWith(pc, target, (await requested).request.pin);
    final laptop = PeerClient(
      host: '127.0.0.1',
      port: pc.server.port,
      token: paired.device.token,
      fingerprint: pc.identity.fingerprint,
    );
    await expectLater(laptop.upload(f, ticket: stolen), throwsA(isA<SidekickException>()));
    await other.server.stop();
  });

  test('permissions switch features off', () async {
    final client = await pair();
    pc.permissions = const Permissions(files: false, input: true);
    expect(() => client.roots(), throwsA(isA<SidekickException>().having((e) => e.status, 'status', 403)));
    expect(await client.info(), isNotNull, reason: 'the rest still works');
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
      ..buttonDown()
      ..buttonUp()
      ..scroll(dy: -120)
      ..key('c', modifiers: ['ctrl'])
      ..text('hi');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await session.close();
    await closed;
    expect(pc.input.log, [
      'move 3 -2',
      'click right 1',
      'down left',
      'up left',
      'scroll 0 -120',
      'key ctrl+c',
      'text hi',
    ]);
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
    test('release numbers compare as numbers, and devices say theirs', () {
      expect(compareVersions('2.1.10', '2.1.9'), 1);
      expect(compareVersions('2.1.2', '2.1.3'), -1);
      expect(compareVersions('2.1', '2.1.0'), 0);
      expect(compareVersions('2.1.3+80', '2.1.3'), 0);
      const me = DeviceInfo(id: 'a', name: 'Mac', platform: DevicePlatform.macos, port: 1, app: '2.1.3');
      expect(DeviceInfo.fromJson(me.toJson()).app, '2.1.3');
      expect(DeviceInfo.fromJson({'id': 'b', 'v': 2}).app, isNull, reason: 'older releases say nothing');
    });

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

    test('device names', () {
      // iOS 16+ only says "iPhone": use the model.
      expect(iosName(name: 'iPhone', modelName: 'iPhone 12'), 'iPhone 12');
      expect(iosName(name: "Michał's iPhone", modelName: 'iPhone 12'), "Michał's iPhone");
      expect(iosName(name: 'iPhone', modelName: 'Unknown device'), 'Unknown iPhone');
      expect(iosName(name: 'iPad', modelName: '', kind: 'iPad'), 'Unknown iPad');
      expect(androidName(name: 'Galaxy S23', manufacturer: 'samsung', model: 'SM-S911B'), 'Galaxy S23');
      expect(androidName(name: '', manufacturer: 'Google', model: 'Pixel 8'), 'Google Pixel 8');
      expect(androidName(name: '', manufacturer: 'samsung', model: 'SM-S911B'), 'Samsung SM-S911B');
      expect(androidName(name: '', manufacturer: 'OnePlus', model: 'OnePlus 12'), 'OnePlus 12');
      expect(androidName(name: '', manufacturer: '', model: ''), 'Unknown Android');
      expect(isLegacyDefaultName('My ios'), isTrue);
      expect(isLegacyDefaultName('My android'), isTrue);
      expect(isLegacyDefaultName('ambiaPC'), isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/pairing_qr.dart';
import 'package:sidekick/platform/hotspot.dart';

/// Who opens the network, as [a] talking to [b].
bool? host(DevicePlatform a, DevicePlatform b, {String aId = 'a', String bId = 'b'}) => directLinkHost(
  mine: a,
  theirs: b,
  myId: aId,
  theirId: bId,
  canHost: a == DevicePlatform.android || a == DevicePlatform.windows,
  canJoin: true,
);

void main() {
  const android = DevicePlatform.android, windows = DevicePlatform.windows;
  const mac = DevicePlatform.macos, iphone = DevicePlatform.ios;

  test('every pair but Apple with Apple gets a direct link, and both sides agree who opens it', () {
    const all = [android, windows, mac, iphone];
    for (final a in all) {
      for (final b in all) {
        final apple = {mac, iphone};
        final ab = host(a, b), ba = host(b, a, aId: 'b', bId: 'a');
        if (apple.contains(a) && apple.contains(b)) {
          expect(ab, isNull, reason: '$a-$b: Apple\'s own link instead');
          continue;
        }
        expect(ab, isNotNull, reason: '$a-$b');
        expect(ab, isNot(ba), reason: '$a-$b: exactly one opens it');
      }
    }
  });

  test('an Android phone opens it, then a PC; Macs and iPhones join', () {
    expect(host(android, windows), isTrue);
    expect(host(windows, android), isFalse);
    expect(host(windows, mac), isTrue);
    expect(host(iphone, windows), isFalse);
    expect(host(iphone, android), isFalse);
    expect(host(mac, android), isFalse);
  });

  test("a QR code carries the network a device opened when it has no Wi-Fi", () {
    const network = HotspotCredentials(
      ssid: 'DIRECT-sk-AB12',
      passphrase: 'k3y with & = ?',
      addresses: ['192.168.137.1'],
    );
    final qr = InviteQr(
      id: 'pc',
      name: 'PC',
      platform: windows,
      addresses: network.addresses,
      port: 53318,
      fingerprint: 'a' * 64,
      secret: 's' * 22,
      network: network,
    );
    final read = PairingQr.parse(qr.encode())! as InviteQr;
    expect(read.network?.ssid, network.ssid);
    expect(read.network?.passphrase, network.passphrase);
    expect(read.network?.addresses, ['192.168.137.1']);
    // Codes without one (on Wi-Fi, or older releases) have none.
    final plain = InviteQr(
      id: 'pc',
      name: 'PC',
      platform: windows,
      addresses: const ['10.0.0.2'],
      port: 53318,
      fingerprint: 'a' * 64,
      secret: 's' * 22,
    );
    expect((PairingQr.parse(plain.encode())! as InviteQr).network, isNull);
  });
}

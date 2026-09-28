import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidekick/core/crypto.dart';

/// Miller-Rabin with fixed bases; plenty to catch a mistyped constant.
bool probablyPrime(BigInt n) {
  if (n < BigInt.two) return false;
  var d = n - BigInt.one;
  var r = 0;
  while (d.isEven) {
    d >>= 1;
    r++;
  }
  for (final a in [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37]) {
    var x = BigInt.from(a).modPow(d, n);
    if (x == BigInt.one || x == n - BigInt.one) continue;
    var composite = true;
    for (var i = 1; i < r; i++) {
      x = x.modPow(BigInt.two, n);
      if (x == n - BigInt.one) {
        composite = false;
        break;
      }
    }
    if (composite) return false;
  }
  return true;
}

void main() {
  test('SPAKE2 group is a 2048-bit safe prime', () {
    expect(spakeP.bitLength, 2048);
    expect(probablyPrime(spakeP), isTrue);
    expect(probablyPrime(spakeQ), isTrue);
  });

  const ctx = 'sidekick-pair-v1|a|fa|b|fb';

  test('SPAKE2: same PIN gives the same keys, a different PIN or context does not', () {
    final a = Spake2(isA: true, pin: '123456', context: ctx);
    final b = Spake2(isA: false, pin: '123456', context: ctx);
    final ka = a.finish(b.message);
    final kb = b.finish(a.message);
    expect(ka.linkKey, kb.linkKey);
    expect(ka.confirmA, kb.confirmA);
    expect(ka.confirmA, isNot(ka.confirmB));

    final wrong = Spake2(isA: false, pin: '123457', context: ctx);
    expect(
      Spake2(isA: true, pin: '123456', context: ctx).finish(wrong.message).linkKey,
      isNot(wrong.finish(a.message).linkKey),
    );

    // A man in the middle shows each side a different certificate.
    final mitm = Spake2(isA: false, pin: '123456', context: 'sidekick-pair-v1|a|fa|b|EVIL');
    final a2 = Spake2(isA: true, pin: '123456', context: ctx);
    expect(a2.finish(mitm.message).linkKey, isNot(mitm.finish(a2.message).linkKey));

    expect(() => a.finish(List.filled(256, 0)), throwsFormatException);
    expect(() => a.finish([1, 2, 3]), throwsFormatException);
  });

  test('seal and unseal', () {
    final key = randomBytes(32);
    final sealed = sealBytes(key, utf8.encode('hello'), aad: [1]);
    expect(utf8.decode(unseal(key, sealed, aad: [1])), 'hello');
    expect(() => unseal(key, sealed, aad: [2]), throwsFormatException);
    expect(() => unseal(randomBytes(32), sealed, aad: [1]), throwsFormatException);
    final tampered = Uint8List.fromList(sealed)..[20] ^= 1;
    expect(() => unseal(key, tampered, aad: [1]), throwsFormatException);
  });

  test('identity serves TLS that a pinned client accepts and a wrong pin rejects', () async {
    final id = Identity.generate();
    final again = Identity.fromJson(id.toJson());
    expect(again.fingerprint, id.fingerprint);

    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, id.serverContext());
    server.listen(
      (r) => r.response
        ..write('ok')
        ..close(),
    );
    try {
      Future<String> get(String pin) async {
        final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
          ..badCertificateCallback = (cert, _, _) => fingerprintOf(cert.der) == pin;
        try {
          final res = await (await client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/'))).close();
          expect(fingerprintOf(res.certificate!.der), id.fingerprint);
          return await utf8.decodeStream(res);
        } finally {
          client.close(force: true);
        }
      }

      expect(await get(id.fingerprint), 'ok');
      await expectLater(get('0' * 64), throwsA(isA<HandshakeException>()));
    } finally {
      await server.close(force: true);
    }
  });
}

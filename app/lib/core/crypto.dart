/// Sidekick's encryption.
///
/// * **Identity:** every device has a self-signed TLS certificate. Its
///   SHA-256 fingerprint is the device's cryptographic identity.
/// * **Wi-Fi:** all traffic is HTTPS. After pairing, each side only accepts
///   the exact certificate it paired with (pinning), so nobody on the
///   network can read or tamper with files, input or media commands.
/// * **Pairing:** the 6-digit PIN runs through SPAKE2, a password-
///   authenticated key exchange. Both certificate fingerprints are part of
///   it, so a man in the middle is detected, and someone watching can't
///   brute-force the PIN offline. It also yields a shared 256-bit key.
/// * **Bluetooth:** requests and responses between paired devices are
///   sealed with AES-256-GCM under that key.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart' as bu;
import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart' as pc;

final _random = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// SHA-256 fingerprint of a DER certificate, as lowercase hex.
String fingerprintOf(List<int> der) => _hex(c.sha256.convert(der).bytes);

Uint8List _derFromPem(String pem) {
  final body = pem.split('\n').where((l) => !l.startsWith('-----')).join().replaceAll(RegExp(r'\s'), '');
  return base64.decode(body);
}

// ------------------------------------------------------------------ identity

/// This device's certificate and private key.
class Identity {
  Identity({required this.certPem, required this.keyPem}) : fingerprint = fingerprintOf(_derFromPem(certPem));

  final String certPem;
  final String keyPem;
  final String fingerprint;

  /// A fresh P-256 key and a self-signed certificate valid for 30 years.
  factory Identity.generate() {
    final pair = bu.CryptoUtils.generateEcKeyPair();
    final private = pair.privateKey as bu.ECPrivateKey;
    final public = pair.publicKey as bu.ECPublicKey;
    final csr = bu.X509Utils.generateEccCsrPem({'CN': 'Sidekick'}, private, public);
    final cert = bu.X509Utils.generateSelfSignedCertificate(private, csr, 365 * 30);
    return Identity(certPem: cert, keyPem: bu.CryptoUtils.encodeEcPrivateKeyToPem(private));
  }

  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  Map<String, String> toJson() => {'cert': certPem, 'key': keyPem};

  factory Identity.fromJson(Map<String, dynamic> json) =>
      Identity(certPem: json['cert'] as String, keyPem: json['key'] as String);
}

// ------------------------------------------------------------------ SPAKE2

/// RFC 3526 group 14: a 2048-bit safe prime p = 2q + 1. We work in the
/// subgroup of squares (order q), which 2 generates since p ≡ 7 (mod 8).
final BigInt _p = BigInt.parse(
  'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD'
  'EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED'
  'EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F'
  '83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B'
  'E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510'
  '15728E5A8AACAA68FFFFFFFFFFFFFFFF',
  radix: 16,
);
final BigInt _q = (_p - BigInt.one) >> 1;
final BigInt _g = BigInt.two;

/// Public for tests, which check the group really is a safe prime.
BigInt get spakeP => _p;
BigInt get spakeQ => _q;

BigInt _bigFrom(List<int> bytes) => BigInt.parse(_hex(bytes), radix: 16);

List<int> _bytesOf(BigInt n, int length) {
  final hex = n.toRadixString(16).padLeft(length * 2, '0');
  return [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
}

const _groupBytes = 256;

/// A group element nobody knows the discrete log of: hash a label to a
/// number and square it into the subgroup.
BigInt _hashToGroup(String label) {
  final out = <int>[];
  for (var i = 0; out.length < _groupBytes + 32; i++) {
    out.addAll(c.sha256.convert(utf8.encode('sidekick-spake2 $label $i')).bytes);
  }
  return (_bigFrom(out) % _p).modPow(BigInt.two, _p);
}

final BigInt _m = _hashToGroup('M');
final BigInt _n = _hashToGroup('N');

List<int> _lengthPrefixed(List<List<int>> parts) {
  final out = <int>[];
  for (final part in parts) {
    out.addAll((ByteData(4)..setUint32(0, part.length)).buffer.asUint8List());
    out.addAll(part);
  }
  return out;
}

/// Keys that come out of a successful SPAKE2 exchange.
class PairingKeys {
  PairingKeys(this.confirmA, this.confirmB, this.linkKey);

  /// MAC keys proving each side derived the same secret.
  final Uint8List confirmA;
  final Uint8List confirmB;

  /// Long-term key shared by the two devices (seals Bluetooth traffic).
  final Uint8List linkKey;
}

/// One side of SPAKE2 over the RFC 3526 group. Side A is the device that
/// types the PIN; side B is the one showing it.
///
/// [context] must be identical on both sides: it binds the device ids and
/// certificate fingerprints, so a man in the middle (who necessarily shows
/// each side a different certificate) ends up with mismatched keys.
class Spake2 {
  Spake2({required this.isA, required String pin, required this.context})
    : _w = _bigFrom(c.sha256.convert(utf8.encode('sidekick-pin|$pin|$context')).bytes) % _q {
    // 320-bit exponents: well past the group's ~112-bit strength.
    _x = _bigFrom(randomBytes(40)) % _q;
    if (_x == BigInt.zero) _x = BigInt.one;
    final blind = (isA ? _m : _n).modPow(_w, _p);
    message = _bytesOf((_g.modPow(_x, _p) * blind) % _p, _groupBytes);
  }

  final bool isA;
  final String context;
  final BigInt _w;
  late final BigInt _x;

  /// What we send to the other side.
  late final List<int> message;

  /// Derives the shared keys from the other side's [theirs] message.
  PairingKeys finish(List<int> theirs) {
    if (theirs.length != _groupBytes) throw const FormatException('Bad pairing message');
    final t = _bigFrom(theirs);
    if (t <= BigInt.one || t >= _p - BigInt.one || t.modPow(_q, _p) != BigInt.one) {
      throw const FormatException('Bad pairing message');
    }
    // Remove their blinding (M^w or N^w) and raise to our secret exponent.
    final unblind = (isA ? _n : _m).modPow(_q - _w, _p);
    final k = ((t * unblind) % _p).modPow(_x, _p);
    final a = isA ? message : theirs;
    final b = isA ? theirs : message;
    final secret = c.sha256
        .convert(_lengthPrefixed([utf8.encode(context), a, b, _bytesOf(k, _groupBytes), _bytesOf(_w, 32)]))
        .bytes;
    Uint8List derive(String label) =>
        Uint8List.fromList(c.Hmac(c.sha256, secret).convert(utf8.encode('sidekick $label')).bytes);
    return PairingKeys(derive('confirm A'), derive('confirm B'), derive('link key'));
  }
}

/// MAC that proves knowledge of a confirm key over the pairing [context].
String confirmTag(Uint8List key, String context) =>
    base64.encode(c.Hmac(c.sha256, key).convert(utf8.encode(context)).bytes);

bool tagsEqual(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Everything both sides feed into SPAKE2, in a fixed order.
String pairingContext({
  required String idA,
  required String fingerprintA,
  required String idB,
  required String fingerprintB,
}) => 'sidekick-pair-v1|$idA|$fingerprintA|$idB|$fingerprintB';

// ------------------------------------------------------------------ sealing

/// AES-256-GCM: `nonce (12 bytes) || ciphertext+tag`.
Uint8List sealBytes(Uint8List key, List<int> plaintext, {List<int> aad = const []}) {
  final nonce = randomBytes(12);
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(true, pc.AEADParameters(pc.KeyParameter(key), 128, nonce, Uint8List.fromList(aad)));
  final out = cipher.process(Uint8List.fromList(plaintext));
  return Uint8List.fromList([...nonce, ...out]);
}

/// Opens bytes from [sealBytes]. Throws [FormatException] if they were tampered with
/// or sealed with another key.
Uint8List unseal(Uint8List key, List<int> sealed, {List<int> aad = const []}) {
  if (sealed.length < 12 + 16) throw const FormatException('Sealed message too short');
  final data = Uint8List.fromList(sealed);
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(false, pc.AEADParameters(pc.KeyParameter(key), 128, data.sublist(0, 12), Uint8List.fromList(aad)));
  try {
    return cipher.process(data.sublist(12));
  } on ArgumentError {
    throw const FormatException('Message failed authentication');
  } on pc.InvalidCipherTextException {
    throw const FormatException('Message failed authentication');
  }
}

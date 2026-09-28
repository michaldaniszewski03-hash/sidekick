import 'dart:convert';
import 'dart:math';

import 'models.dart';

final _random = Random.secure();

/// 32 random bytes, URL-safe base64. Used for pairing tokens.
String newToken() => base64Url.encode(List<int>.generate(32, (_) => _random.nextInt(256))).replaceAll('=', '');

/// 16 random bytes as hex. Used for device ids.
String newDeviceId() =>
    List<int>.generate(16, (_) => _random.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _newPin() => _random.nextInt(1000000).toString().padLeft(6, '0');

/// Compares two strings without leaking where they differ via timing.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Peers that are allowed to control this device.
class TrustStore {
  TrustStore([Iterable<TrustedPeer> peers = const []]) : _peers = {for (final p in peers) p.id: p};

  final Map<String, TrustedPeer> _peers;

  /// Called after every change so the app can persist the store.
  void Function()? onChanged;

  List<TrustedPeer> get peers => List.unmodifiable(_peers.values);

  TrustedPeer? byToken(String token) {
    TrustedPeer? match;
    for (final peer in _peers.values) {
      if (constantTimeEquals(peer.token, token)) match = peer;
    }
    return match;
  }

  TrustedPeer? byId(String id) => _peers[id];

  void add(TrustedPeer peer) {
    _peers[peer.id] = peer;
    onChanged?.call();
  }

  void remove(String id) {
    if (_peers.remove(id) != null) onChanged?.call();
  }
}

/// An incoming request to pair, waiting for the user on the other device to
/// type the [pin] we display.
class PairingRequest {
  PairingRequest(this.device) : pin = _newPin(), expires = DateTime.now().add(const Duration(minutes: 2));

  final DeviceInfo device;
  final String pin;
  final DateTime expires;
  int attempts = 0;
  bool cancelled = false;

  static const maxAttempts = 5;

  bool get isOpen => !cancelled && attempts < maxAttempts && DateTime.now().isBefore(expires);
}

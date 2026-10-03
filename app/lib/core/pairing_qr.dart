import '../platform/hotspot.dart';
import 'models.dart';

/// What a Sidekick QR code says. Two kinds:
///
/// * [InviteQr] ("Show QR code"): everything needed to find this device
///   and pair with it, with a one-time secret in place of the 6-digit code.
/// * [PinQr]: the 6-digit code on the pairing screen, so the other device
///   can scan it instead of typing it.
///
/// Both are `sidekick://` links. The fingerprint in an invite is checked
/// against the certificate the device presents, so a QR code can't send
/// you to a look-alike.
sealed class PairingQr {
  const PairingQr();

  /// Null for anything that isn't a Sidekick QR code.
  static PairingQr? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'sidekick') return null;
    final q = uri.queryParameters;
    final id = q['id'];
    if (id == null || id.isEmpty) return null;
    switch (uri.host) {
      case 'pair':
        final fingerprint = q['f'];
        final secret = q['s'];
        final port = int.tryParse(q['p'] ?? '');
        if (fingerprint == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) return null;
        if (secret == null || secret.length < 16 || port == null || port <= 0 || port > 65535) return null;
        return InviteQr(
          id: id,
          name: q['n'] ?? 'Device',
          platform: platformFromName(q['pl']),
          addresses: [
            for (final a in (q['a'] ?? '').split(','))
              if (a.isNotEmpty) a,
          ],
          port: port,
          fingerprint: fingerprint,
          secret: secret,
          network: (q['ws'] ?? '').isEmpty || (q['wk'] ?? '').isEmpty
              ? null
              : HotspotCredentials(
                  ssid: q['ws']!,
                  passphrase: q['wk']!,
                  security: q['wt'] ?? 'wpa2',
                  addresses: [
                    for (final a in (q['a'] ?? '').split(','))
                      if (a.isNotEmpty) a,
                  ],
                ),
        );
      case 'pin':
        final pin = q['c'];
        if (pin == null || !RegExp(r'^\d{6}$').hasMatch(pin)) return null;
        return PinQr(id: id, pin: pin);
    }
    return null;
  }
}

class InviteQr extends PairingQr {
  const InviteQr({
    required this.id,
    required this.name,
    required this.platform,
    required this.addresses,
    required this.port,
    required this.fingerprint,
    required this.secret,
    this.network,
  });

  final String id;
  final String name;
  final DevicePlatform platform;

  /// The device's IP addresses (none when it's offline: then Bluetooth).
  final List<String> addresses;
  final int port;
  final String fingerprint;
  final String secret;

  /// A network the device opened because it has no Wi-Fi (Android, Windows):
  /// the scanner joins it to pair, with no router and no Bluetooth.
  final HotspotCredentials? network;

  String encode() => Uri(
    scheme: 'sidekick',
    host: 'pair',
    queryParameters: {
      'v': '1',
      'id': id,
      'n': name,
      'pl': platform.name,
      'a': addresses.join(','),
      'p': '$port',
      'f': fingerprint,
      's': secret,
      if (network case final n?) ...{'ws': n.ssid, 'wk': n.passphrase, 'wt': n.security},
    },
  ).toString();
}

class PinQr extends PairingQr {
  const PinQr({required this.id, required this.pin});

  /// The device showing the code.
  final String id;
  final String pin;

  String encode() => Uri(scheme: 'sidekick', host: 'pin', queryParameters: {'id': id, 'c': pin}).toString();
}

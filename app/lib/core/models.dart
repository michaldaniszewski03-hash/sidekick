/// Shared data types for the Sidekick protocol (v2).
///
/// Everything that crosses the network is plain JSON so that the Android,
/// iOS and macOS builds of this same codebase can talk to each other.
library;

/// 2: everything is encrypted (HTTPS with pinned certificates, SPAKE2
/// pairing, sealed Bluetooth). Version 1 devices can't pair with us.
const int protocolVersion = 2;

/// TCP port for the HTTP/WebSocket server and UDP port for discovery.
const int sidekickPort = 53318;

/// Multicast group used for discovery announcements.
const String multicastGroup = '224.0.0.168';

enum DevicePlatform { windows, macos, linux, android, ios, unknown }

DevicePlatform platformFromName(String? name) =>
    DevicePlatform.values.firstWhere((p) => p.name == name, orElse: () => DevicePlatform.unknown);

/// What a device lets its paired peers do to it.
class Capabilities {
  const Capabilities({this.files = false, this.input = false});

  /// Peers can browse, download and upload files.
  final bool files;

  /// Peers can move the mouse and type.
  final bool input;

  Map<String, dynamic> toJson() => {'files': files, 'input': input};

  factory Capabilities.fromJson(Map<String, dynamic>? json) =>
      Capabilities(files: json?['files'] == true, input: json?['input'] == true);
}

/// A device on the network, as announced over discovery or `/v1/info`.
class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.port,
    this.capabilities = const Capabilities(),
    this.address,
    this.version = protocolVersion,
    this.fingerprint,
    this.app,
  });

  /// The Sidekick release it runs ("2.1.3"); null before 2.1.3, which didn't
  /// say. Lets the other device point out that one of them needs updating.
  final String? app;

  /// SHA-256 of the device's certificate, as it announces it. Only a hint
  /// for the UI ("this device was reset, pair again"): trust comes from the
  /// certificate checked on every connection, never from this field.
  final String? fingerprint;

  /// Protocol version the device speaks (see [protocolVersion]).
  final int version;

  final String id;
  final String name;
  final DevicePlatform platform;
  final int port;
  final Capabilities capabilities;

  /// IP address we reached this device on. Not part of the wire format;
  /// filled in by whoever received the announcement.
  final String? address;

  bool get isDesktop => const {DevicePlatform.windows, DevicePlatform.macos, DevicePlatform.linux}.contains(platform);

  Uri baseUri() => Uri(scheme: 'https', host: address, port: port);

  DeviceInfo copyWith({String? name, String? address, Capabilities? capabilities}) => DeviceInfo(
    id: id,
    name: name ?? this.name,
    platform: platform,
    port: port,
    capabilities: capabilities ?? this.capabilities,
    address: address ?? this.address,
    version: version,
    fingerprint: fingerprint,
    app: app,
  );

  Map<String, dynamic> toJson() => {
    'v': protocolVersion,
    'id': id,
    'name': name,
    'platform': platform.name,
    'port': port,
    'caps': capabilities.toJson(),
    'fp': ?fingerprint,
    'app': ?app,
  };

  factory DeviceInfo.fromJson(Map<String, dynamic> json, {String? address}) => DeviceInfo(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? 'Unknown device',
    platform: platformFromName(json['platform'] as String?),
    port: (json['port'] as num?)?.toInt() ?? sidekickPort,
    capabilities: Capabilities.fromJson(json['caps'] as Map<String, dynamic>?),
    address: address,
    version: (json['v'] as num?)?.toInt() ?? 1,
    fingerprint: json['fp'] as String?,
    app: json['app'] as String?,
  );
}

/// Compares release numbers like "2.1.10" and "2.1.9" (negative: [a] is
/// older). Anything that isn't a number counts as 0.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [for (final x in v.split('+').first.split('.')) int.tryParse(x) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// A device we have paired with. [token] is what *we* send to *them*.
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.token,
    required this.fingerprint,
    required this.key,
    this.lastAddress,
    this.lastPort = sidekickPort,
  });

  final String id;
  String name;
  final DevicePlatform platform;
  final String token;

  /// SHA-256 of their TLS certificate; we accept no other.
  final String fingerprint;

  /// Shared key from pairing (base64), seals Bluetooth traffic.
  final String key;
  String? lastAddress;
  int lastPort;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform.name,
    'token': token,
    'fingerprint': fingerprint,
    'key': key,
    'lastAddress': lastAddress,
    'lastPort': lastPort,
  };

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: platformFromName(json['platform'] as String?),
    token: json['token'] as String,
    fingerprint: json['fingerprint'] as String,
    key: json['key'] as String,
    lastAddress: json['lastAddress'] as String?,
    lastPort: (json['lastPort'] as num?)?.toInt() ?? sidekickPort,
  );
}

/// A device that is allowed to control *us*. [token] is what they send us.
class TrustedPeer {
  TrustedPeer({
    required this.id,
    required this.name,
    required this.platform,
    required this.token,
    required this.fingerprint,
    required this.key,
  });

  final String id;
  String name;
  final DevicePlatform platform;
  final String token;

  /// SHA-256 of their TLS certificate.
  final String fingerprint;

  /// Shared key from pairing (base64), seals Bluetooth traffic.
  final String key;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform.name,
    'token': token,
    'fingerprint': fingerprint,
    'key': key,
  };

  factory TrustedPeer.fromJson(Map<String, dynamic> json) => TrustedPeer(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: platformFromName(json['platform'] as String?),
    token: json['token'] as String,
    fingerprint: json['fingerprint'] as String,
    key: json['key'] as String,
  );
}

/// One entry in a remote directory listing.
class RemoteEntry {
  const RemoteEntry({required this.name, required this.path, required this.isDir, this.size = 0, this.modified});

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'dir': isDir,
    'size': size,
    'modified': modified?.toUtc().toIso8601String(),
  };

  factory RemoteEntry.fromJson(Map<String, dynamic> json) => RemoteEntry(
    name: json['name'] as String,
    path: json['path'] as String,
    isDir: json['dir'] == true,
    size: (json['size'] as num?)?.toInt() ?? 0,
    modified: json['modified'] == null ? null : DateTime.tryParse(json['modified'] as String),
  );
}

/// How a file was protected on its way between two devices. Recorded from
/// the connection that actually carried it, never assumed.
class TransferSecurity {
  const TransferSecurity.wifi({required this.certificate}) : bluetooth = false;
  const TransferSecurity.bluetooth() : bluetooth = true, certificate = null;

  /// Sealed with AES-256-GCM under the pairing key (else TLS over Wi-Fi).
  final bool bluetooth;

  /// SHA-256 of the certificate the other device presented over Wi-Fi,
  /// which matched the one it paired with (else the connection is refused).
  final String? certificate;

  String get label => bluetooth ? 'Encrypted · Bluetooth' : 'Encrypted · Wi-Fi';
}

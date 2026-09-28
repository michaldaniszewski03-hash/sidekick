/// Shared data types for the Sidekick protocol (v1).
///
/// Everything that crosses the network is plain JSON so that the Android,
/// iOS and macOS builds of this same codebase can talk to each other.
library;

const int protocolVersion = 1;

/// TCP port for the HTTP/WebSocket server and UDP port for discovery.
const int sidekickPort = 53318;

/// Multicast group used for discovery announcements.
const String multicastGroup = '224.0.0.168';

enum DevicePlatform { windows, macos, linux, android, ios, unknown }

DevicePlatform platformFromName(String? name) =>
    DevicePlatform.values.firstWhere((p) => p.name == name, orElse: () => DevicePlatform.unknown);

/// What a device lets its paired peers do to it.
class Capabilities {
  const Capabilities({this.files = false, this.media = false, this.input = false});

  /// Peers can browse, download and upload files.
  final bool files;

  /// Peers can see and control what's playing.
  final bool media;

  /// Peers can move the mouse and type.
  final bool input;

  Map<String, dynamic> toJson() => {'files': files, 'media': media, 'input': input};

  factory Capabilities.fromJson(Map<String, dynamic>? json) =>
      Capabilities(files: json?['files'] == true, media: json?['media'] == true, input: json?['input'] == true);
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
  });

  final String id;
  final String name;
  final DevicePlatform platform;
  final int port;
  final Capabilities capabilities;

  /// IP address we reached this device on. Not part of the wire format;
  /// filled in by whoever received the announcement.
  final String? address;

  bool get isDesktop => const {DevicePlatform.windows, DevicePlatform.macos, DevicePlatform.linux}.contains(platform);

  Uri baseUri() => Uri(scheme: 'http', host: address, port: port);

  DeviceInfo copyWith({String? name, String? address, Capabilities? capabilities}) => DeviceInfo(
    id: id,
    name: name ?? this.name,
    platform: platform,
    port: port,
    capabilities: capabilities ?? this.capabilities,
    address: address ?? this.address,
  );

  Map<String, dynamic> toJson() => {
    'v': protocolVersion,
    'id': id,
    'name': name,
    'platform': platform.name,
    'port': port,
    'caps': capabilities.toJson(),
  };

  factory DeviceInfo.fromJson(Map<String, dynamic> json, {String? address}) => DeviceInfo(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? 'Unknown device',
    platform: platformFromName(json['platform'] as String?),
    port: (json['port'] as num?)?.toInt() ?? sidekickPort,
    capabilities: Capabilities.fromJson(json['caps'] as Map<String, dynamic>?),
    address: address,
  );
}

/// A device we have paired with. [token] is what *we* send to *them*.
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.token,
    this.lastAddress,
    this.lastPort = sidekickPort,
  });

  final String id;
  String name;
  final DevicePlatform platform;
  final String token;
  String? lastAddress;
  int lastPort;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform.name,
    'token': token,
    'lastAddress': lastAddress,
    'lastPort': lastPort,
  };

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: platformFromName(json['platform'] as String?),
    token: json['token'] as String,
    lastAddress: json['lastAddress'] as String?,
    lastPort: (json['lastPort'] as num?)?.toInt() ?? sidekickPort,
  );
}

/// A device that is allowed to control *us*. [token] is what they send us.
class TrustedPeer {
  TrustedPeer({required this.id, required this.name, required this.platform, required this.token});

  final String id;
  String name;
  final DevicePlatform platform;
  final String token;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'platform': platform.name, 'token': token};

  factory TrustedPeer.fromJson(Map<String, dynamic> json) => TrustedPeer(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: platformFromName(json['platform'] as String?),
    token: json['token'] as String,
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

enum PlaybackStatus { playing, paused, stopped, unknown }

/// What's playing on a device right now.
class MediaStatus {
  const MediaStatus({
    this.available = false,
    this.title = '',
    this.artist = '',
    this.app = '',
    this.status = PlaybackStatus.unknown,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.canSeek = false,
    this.volume,
    this.muted = false,
    this.nowPlaying = true,
    this.canNext = true,
    this.canPrevious = true,
    this.note,
  });

  /// False when nothing is playing or the platform can't report it.
  final bool available;
  final String title;
  final String artist;

  /// The app that owns the session, e.g. "Spotify" or "chrome".
  final String app;
  final PlaybackStatus status;
  final Duration position;
  final Duration duration;
  final bool canSeek;

  /// System volume from 0.0 to 1.0, or null if unknown.
  final double? volume;
  final bool muted;

  /// False when the platform can't report what's playing at all (macOS),
  /// as opposed to nothing playing right now.
  final bool nowPlaying;

  /// Whether the playing app accepts next/previous. YouTube, for example,
  /// only offers "next" in a playlist or with autoplay's up-next.
  final bool canNext;
  final bool canPrevious;

  /// Why now-playing info is missing, if something went wrong.
  final String? note;

  bool get isPlaying => status == PlaybackStatus.playing;

  Map<String, dynamic> toJson() => {
    'available': available,
    'title': title,
    'artist': artist,
    'app': app,
    'status': status.name,
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
    'canSeek': canSeek,
    'volume': volume,
    'muted': muted,
    'nowPlaying': nowPlaying,
    'canNext': canNext,
    'canPrevious': canPrevious,
    'note': note,
  };

  factory MediaStatus.fromJson(Map<String, dynamic> json) => MediaStatus(
    available: json['available'] == true,
    title: (json['title'] as String?) ?? '',
    artist: (json['artist'] as String?) ?? '',
    app: (json['app'] as String?) ?? '',
    status: PlaybackStatus.values.firstWhere((s) => s.name == json['status'], orElse: () => PlaybackStatus.unknown),
    position: Duration(milliseconds: (json['positionMs'] as num?)?.toInt() ?? 0),
    duration: Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
    canSeek: json['canSeek'] == true,
    volume: (json['volume'] as num?)?.toDouble(),
    muted: json['muted'] == true,
    nowPlaying: json['nowPlaying'] != false,
    canNext: json['canNext'] != false,
    canPrevious: json['canPrevious'] != false,
    note: json['note'] as String?,
  );
}

/// Commands the media endpoint accepts.
enum MediaAction { playPause, play, pause, next, previous, stop, seek, setVolume, volumeUp, volumeDown, toggleMute }

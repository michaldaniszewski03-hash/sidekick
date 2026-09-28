import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

import 'models.dart';
import 'trust.dart';

class SidekickException implements Exception {
  SidekickException(this.message, {this.status});
  final String message;
  final int? status;

  bool get notPaired => status == 401;

  @override
  String toString() => message;
}

/// Progress callback for transfers: bytes done out of [total] (0 if unknown).
typedef Progress = void Function(int done, int total);

/// Talks to one remote Sidekick device.
class PeerClient {
  PeerClient({required this.host, this.port = sidekickPort, this.token});

  factory PeerClient.forDevice(PairedDevice device) =>
      PeerClient(host: device.lastAddress ?? '', port: device.lastPort, token: device.token);

  final String host;
  final int port;
  final String? token;

  static final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 15);

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: host, port: port, path: path, queryParameters: query);

  Future<HttpClientResponse> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? json,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final req = await _http.openUrl(method, _uri(path, query)).timeout(timeout);
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (json != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(json));
      }
      final res = await req.close().timeout(timeout);
      if (res.statusCode >= 400) throw await _failure(res);
      return res;
    } on SocketException {
      throw SidekickException("Can't reach $host. Check both devices are on the same network.");
    } on TimeoutException {
      throw SidekickException('$host took too long to answer.');
    } on HttpException catch (e) {
      throw SidekickException('Connection problem: ${e.message}');
    }
  }

  static Future<SidekickException> _failure(HttpClientResponse res) async {
    var message = 'Request failed (${res.statusCode})';
    try {
      final body = jsonDecode(await utf8.decodeStream(res));
      if (body is Map && body['error'] is String) message = body['error'] as String;
    } catch (_) {}
    return SidekickException(message, status: res.statusCode);
  }

  Future<dynamic> _getJson(String path, [Map<String, String>? query]) async {
    final res = await _send('GET', path, query: query);
    return jsonDecode(await utf8.decodeStream(res));
  }

  Future<dynamic> _postJson(String path, Object body) async {
    final res = await _send('POST', path, json: body);
    return jsonDecode(await utf8.decodeStream(res));
  }

  // ------------------------------------------------------------ discovery

  /// Fetches the device's identity. Works without pairing.
  Future<DeviceInfo> info({Duration timeout = const Duration(seconds: 3)}) async {
    final res = await _send('GET', '/v1/info', timeout: timeout);
    final json = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
    return DeviceInfo.fromJson(json, address: host);
  }

  // ------------------------------------------------------------ pairing

  /// Asks the device to show a pairing code. Returns its identity.
  Future<DeviceInfo> requestPairing(DeviceInfo me) async {
    final json = await _postJson('/v1/pair/request', {'device': me.toJson()}) as Map<String, dynamic>;
    return DeviceInfo.fromJson(json['device'] as Map<String, dynamic>, address: host);
  }

  /// Sends the code the user typed. On success returns a [PairedDevice] we
  /// can use to control them, and the token they must use with us
  /// (`tokenForThem`), which the caller adds to its [TrustStore].
  Future<({PairedDevice device, String tokenForThem})> confirmPairing(String myId, String pin) async {
    final tokenForThem = newToken();
    final json = await _postJson('/v1/pair/confirm', {
      'id': myId,
      'pin': pin.replaceAll(RegExp(r'\s'), ''),
      'token': tokenForThem,
    }) as Map<String, dynamic>;
    final info = DeviceInfo.fromJson(json['device'] as Map<String, dynamic>, address: host);
    return (
      device: PairedDevice(
        id: info.id,
        name: info.name,
        platform: info.platform,
        token: json['token'] as String,
        lastAddress: host,
        lastPort: info.port,
      ),
      tokenForThem: tokenForThem,
    );
  }

  Future<void> unpair() => _postJson('/v1/unpair', const {});

  // ------------------------------------------------------------ files

  Future<List<RemoteEntry>> roots() async =>
      (await _getJson('/v1/fs/roots') as List).map((e) => RemoteEntry.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<RemoteEntry>> list(String path) async => (await _getJson('/v1/fs/list', {'path': path}) as List)
      .map((e) => RemoteEntry.fromJson(e as Map<String, dynamic>))
      .toList();

  /// Downloads [remotePath] into [destination]. The file is written under a
  /// temporary name and only renamed once complete.
  Future<File> download(String remotePath, File destination, {Progress? onProgress}) async {
    final res = await _send(
      'GET',
      '/v1/fs/download',
      query: {'path': remotePath},
      timeout: const Duration(seconds: 30),
    );
    final total = res.contentLength < 0 ? 0 : res.contentLength;
    final partial = File('${destination.path}.sidekick-part');
    final sink = partial.openWrite();
    var done = 0;
    try {
      await sink.addStream(
        res.map((chunk) {
          done += chunk.length;
          onProgress?.call(done, total);
          return chunk;
        }),
      );
      await sink.close();
      if (total > 0 && done != total) throw SidekickException('Download was cut off');
      return await partial.rename(destination.path);
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  /// Uploads [file]. Without [remoteDir] it goes to the device's receive
  /// folder. Returns the path it was saved to on the other device.
  Future<String> upload(File file, {String? name, String? remoteDir, Progress? onProgress}) async {
    final total = await file.length();
    final query = {'name': name ?? file.uri.pathSegments.last, 'dir': ?remoteDir};
    try {
      final req = await _http.openUrl('POST', _uri('/v1/fs/upload', query));
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.contentLength = total;
      var done = 0;
      await req.addStream(
        file.openRead().map((chunk) {
          done += chunk.length;
          onProgress?.call(done, total);
          return chunk;
        }),
      );
      final res = await req.close();
      if (res.statusCode >= 400) throw await _failure(res);
      final json = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      return json['path'] as String;
    } on SocketException {
      throw SidekickException('Lost connection to $host while sending.');
    } on HttpException catch (e) {
      throw SidekickException('Connection problem: ${e.message}');
    }
  }

  // ------------------------------------------------------------ media

  Future<MediaStatus> mediaStatus() async => MediaStatus.fromJson(await _getJson('/v1/media') as Map<String, dynamic>);

  Future<void> media(MediaAction action, {Duration? position, double? volume}) => _postJson('/v1/media', {
    'action': action.name,
    if (position != null) 'positionMs': position.inMilliseconds,
    'volume': ?volume,
  });

  // ------------------------------------------------------------ input

  Future<InputSession> openInput() async {
    final channel = IOWebSocketChannel.connect(
      Uri(scheme: 'ws', host: host, port: port, path: '/v1/input'),
      headers: {if (token != null) 'authorization': 'Bearer $token'},
      pingInterval: const Duration(seconds: 10),
      connectTimeout: const Duration(seconds: 4),
    );
    try {
      await channel.ready;
    } catch (_) {
      throw SidekickException("Couldn't start remote control. Is it turned on in the other device's settings?");
    }
    return InputSession._(channel);
  }
}

/// A live remote-control connection. Small mouse moves are coalesced so a
/// fast touchpad doesn't flood the network.
class InputSession {
  InputSession._(this._channel) {
    _channel.stream.listen((_) {}, onDone: () => _closed.complete(), onError: (_) {});
  }

  final IOWebSocketChannel _channel;
  final _closed = Completer<void>();
  double _dx = 0, _dy = 0;
  Timer? _flush;

  Future<void> get closed => _closed.future;
  bool get isOpen => !_closed.isCompleted;

  void _raw(Map<String, Object?> msg) {
    if (isOpen) _channel.sink.add(jsonEncode(msg));
  }

  /// Sends [msg] after any pending movement, so a click lands where the
  /// pointer was moved to.
  void _send(Map<String, Object?> msg) {
    _flushMove();
    _raw(msg);
  }

  void _flushMove() {
    _flush?.cancel();
    _flush = null;
    final x = _dx.truncate(), y = _dy.truncate();
    _dx -= x;
    _dy -= y;
    if (x != 0 || y != 0) _raw({'t': 'move', 'dx': x, 'dy': y});
  }

  void move(double dx, double dy) {
    _dx += dx;
    _dy += dy;
    _flush ??= Timer(const Duration(milliseconds: 12), _flushMove);
  }

  void click({String button = 'left', int count = 1}) => _send({'t': 'click', 'b': button, 'n': count});
  void buttonDown([String button = 'left']) => _send({'t': 'down', 'b': button});
  void buttonUp([String button = 'left']) => _send({'t': 'up', 'b': button});
  void scroll({int dx = 0, int dy = 0}) => _send({'t': 'scroll', 'dx': dx, 'dy': dy});
  void key(String key, {List<String> modifiers = const []}) => _send({'t': 'key', 'k': key, 'mods': modifiers});
  void text(String text) => _send({'t': 'text', 's': text});

  Future<void> close() async {
    _flush?.cancel();
    await _channel.sink.close();
  }
}

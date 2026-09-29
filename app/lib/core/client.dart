import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

import '../platform/hotspot.dart';
import 'ble_protocol.dart';
import 'crypto.dart';
import 'models.dart';
import 'trust.dart';

class SidekickException implements Exception {
  SidekickException(this.message, {this.status, this.identityChanged = false});
  final String message;
  final int? status;

  /// The device presented a different certificate than it paired with (it
  /// was reset or reinstalled): it has to be paired again.
  final bool identityChanged;

  bool get notPaired => status == 401;

  @override
  String toString() => message;
}

/// Progress callback for transfers: bytes done out of [total] (0 if unknown).
typedef Progress = void Function(int done, int total);

/// A device we're about to pair with: who it is and which certificate it
/// showed us.
typedef PairingTarget = ({DeviceInfo device, String fingerprint});

/// Talks to one remote Sidekick device, over Wi-Fi (HTTPS) or, when there's
/// no shared network, over Bluetooth ([ble]).
///
/// With a [fingerprint], only a server presenting exactly that certificate
/// is accepted. Without one (before pairing) any certificate is accepted,
/// and pairing proves which one was real.
class PeerClient {
  PeerClient({required this.host, this.port = sidekickPort, this.token, this.fingerprint, this.ble, this.seal});

  /// Same API over a Bluetooth connection. Slower, and no remote control.
  /// Paired requests are sealed with [seal].
  PeerClient.bluetooth(BleRpcClient this.ble, {this.token, this.seal})
    : host = 'bluetooth',
      port = 0,
      fingerprint = null;

  factory PeerClient.forDevice(PairedDevice device) => PeerClient(
    host: device.lastAddress ?? '',
    port: device.lastPort,
    token: device.token,
    fingerprint: device.fingerprint,
  );

  final String host;
  final int port;
  final String? token;
  final String? fingerprint;
  final BleRpcClient? ble;
  final BleSeal? seal;

  bool get viaBluetooth => ble != null;

  /// How the last successful request was protected: the certificate the
  /// device presented over Wi-Fi, or Bluetooth sealing. Null until a request
  /// succeeds (and over Bluetooth before pairing, which isn't sealed).
  TransferSecurity? lastSecurity;

  void _noteTls(HttpClientResponse res) {
    final cert = res.certificate;
    if (cert != null) lastSecurity = TransferSecurity.wifi(certificate: fingerprintOf(cert.der));
  }

  /// The IP address to remember for this device (none over Bluetooth).
  String? get _address => ble == null ? host : null;

  static final Map<String, HttpClient> _clients = {};

  /// One HTTP client per pinned certificate (and one that accepts any, for
  /// discovery and pairing).
  HttpClient get _http => _clients.putIfAbsent(fingerprint ?? '', () {
    final pin = fingerprint;
    return HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 15)
      ..badCertificateCallback = (cert, _, _) => pin == null || fingerprintOf(cert.der) == pin;
  });

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'https', host: host, port: port, path: path, queryParameters: query);

  SidekickException _tlsFailure() => fingerprint == null
      ? SidekickException("Couldn't connect securely to $host. Make sure both devices run Sidekick 0.3 or newer.")
      : SidekickException(
          "The other device has a new security key (it was reset or updated from 1.0.x). Pair it again.",
          identityChanged: true,
        );

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
      _noteTls(res);
      return res;
    } on HandshakeException {
      throw _tlsFailure();
    } on TlsException {
      throw _tlsFailure();
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

  Map<String, String> get _authHeaders => {if (token != null) 'authorization': 'Bearer $token'};

  /// A request over Bluetooth, with the same error handling as HTTP.
  Future<BleResponse> _bleSend(
    String method,
    String path, {
    Map<String, String>? query,
    List<int> body = const [],
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final BleResponse res;
    try {
      res = await ble!.request(
        method,
        path,
        query: query,
        headers: {..._authHeaders, ...headers},
        body: body,
        timeout: timeout,
        seal: seal,
      );
    } on TimeoutException {
      throw SidekickException('The device took too long to answer over Bluetooth.');
    } on StateError catch (e) {
      throw SidekickException(e.message);
    }
    // A success over a sealed link only completes if the reply decrypted
    // with our pairing key (see BleRpcClient).
    if (res.status < 400 && seal != null) lastSecurity = const TransferSecurity.bluetooth();
    if (res.status >= 400) {
      var message = 'Request failed (${res.status})';
      try {
        final json = jsonDecode(utf8.decode(res.body));
        if (json is Map && json['error'] is String) message = json['error'] as String;
      } catch (_) {}
      throw SidekickException(message, status: res.status);
    }
    return res;
  }

  Future<dynamic> _getJson(String path, [Map<String, String>? query]) async {
    if (ble != null) return jsonDecode(utf8.decode((await _bleSend('GET', path, query: query)).body));
    final res = await _send('GET', path, query: query);
    return jsonDecode(await utf8.decodeStream(res));
  }

  Future<dynamic> _postJson(String path, Object body, {Duration timeout = const Duration(seconds: 30)}) async {
    if (ble != null) {
      final res = await _bleSend(
        'POST',
        path,
        body: utf8.encode(jsonEncode(body)),
        headers: {'content-type': 'application/json'},
        timeout: timeout,
      );
      return jsonDecode(utf8.decode(res.body));
    }
    final res = await _send('POST', path, json: body);
    return jsonDecode(await utf8.decodeStream(res));
  }

  // ------------------------------------------------------------ discovery

  /// Fetches the device's identity. Works without pairing.
  Future<DeviceInfo> info({Duration timeout = const Duration(seconds: 3)}) async {
    if (ble != null) {
      final res = await _bleSend('GET', '/v1/info', timeout: const Duration(seconds: 15));
      return DeviceInfo.fromJson(jsonDecode(utf8.decode(res.body)) as Map<String, dynamic>);
    }
    final res = await _send('GET', '/v1/info', timeout: timeout);
    final json = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
    return DeviceInfo.fromJson(json, address: host);
  }

  // ------------------------------------------------------------ pairing

  /// Asks the device to show a pairing code. Returns who it is and the
  /// certificate it presented.
  Future<PairingTarget> requestPairing(DeviceInfo me, {required String myFingerprint}) async {
    Map<String, dynamic> json;
    String? seen;
    if (ble != null) {
      json = await _postJson('/v1/pair/request', {
        'device': me.toJson(),
        'fingerprint': myFingerprint,
      }) as Map<String, dynamic>;
    } else {
      final res = await _send('POST', '/v1/pair/request', json: {'device': me.toJson(), 'fingerprint': myFingerprint});
      seen = res.certificate == null ? null : fingerprintOf(res.certificate!.der);
      json = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
    }
    final claimed = json['fingerprint'];
    if (claimed is! String) throw SidekickException('Update Sidekick on the other device to pair with it.');
    // Over Wi-Fi the certificate we actually saw is what we pin; pairing
    // then proves the other side really has it.
    if (seen != null && seen != claimed) throw SidekickException('The connection was tampered with. Try again.');
    return (
      device: DeviceInfo.fromJson(json['device'] as Map<String, dynamic>, address: _address),
      fingerprint: claimed,
    );
  }

  /// Runs SPAKE2 with the code the user typed. On success returns a
  /// [PairedDevice] we can use to control them, and the token and key they
  /// use with us (`tokenForThem`, `key`), which the caller adds to its
  /// [TrustStore].
  Future<({PairedDevice device, String tokenForThem, String key})> confirmPairing({
    required String myId,
    required String myFingerprint,
    required PairingTarget target,
    required String pin,
  }) async {
    final context = pairingContext(
      idA: myId,
      fingerprintA: myFingerprint,
      idB: target.device.id,
      fingerprintB: target.fingerprint,
    );
    final spake = Spake2(isA: true, pin: pin.replaceAll(RegExp(r'\s'), ''), context: context);
    final start = await _postJson('/v1/pair/start', {'id': myId, 'msg': base64.encode(spake.message)}) as Map;
    final PairingKeys keys;
    try {
      keys = spake.finish(base64.decode(start['msg'] as String));
    } on FormatException {
      throw SidekickException('The other device sent a bad pairing message.');
    }
    final tokenForThem = newToken();
    final json = await _postJson('/v1/pair/confirm', {
      'id': myId,
      'confirm': confirmTag(keys.confirmA, context),
      'token': base64.encode(sealBytes(keys.linkKey, utf8.encode(tokenForThem), aad: utf8.encode('token A'))),
    }) as Map<String, dynamic>;
    // They must prove the same key too, or it's not really them.
    final theirConfirm = json['confirm'];
    if (theirConfirm is! String || !tagsEqual(confirmTag(keys.confirmB, context), theirConfirm)) {
      throw SidekickException("Couldn't verify the other device. Try pairing again.");
    }
    final String token;
    try {
      token = utf8.decode(unseal(keys.linkKey, base64.decode(json['token'] as String), aad: utf8.encode('token B')));
    } on FormatException {
      throw SidekickException("Couldn't verify the other device. Try pairing again.");
    }
    final info = DeviceInfo.fromJson(json['device'] as Map<String, dynamic>, address: _address);
    final key = base64.encode(keys.linkKey);
    return (
      device: PairedDevice(
        id: info.id,
        name: info.name,
        platform: info.platform,
        token: token,
        fingerprint: target.fingerprint,
        key: key,
        lastAddress: _address,
        lastPort: info.port,
      ),
      tokenForThem: tokenForThem,
      key: key,
    );
  }

  Future<void> unpair() => _postJson('/v1/unpair', const {});

  // ------------------------------------------------------------ direct link

  /// Asks the device (over Bluetooth) to open a hotspot for us.
  Future<HotspotCredentials> startHotspot() async => HotspotCredentials.fromJson(
    await _postJson('/v1/link/hotspot', const {}, timeout: const Duration(seconds: 40)) as Map<String, dynamic>,
  );

  /// Asks the device (over Bluetooth) to join our hotspot. Returns our
  /// addresses it can reach.
  Future<List<String>> joinHotspot(HotspotCredentials creds) async {
    final json = await _postJson('/v1/link/join', creds.toJson(), timeout: const Duration(seconds: 60)) as Map;
    return [for (final a in (json['addresses'] as List?) ?? const []) '$a'];
  }

  /// Tells the device we're done with the direct link.
  Future<void> releaseLink() => _postJson('/v1/link/release', const {}, timeout: const Duration(seconds: 5));

  // ------------------------------------------------------------ files

  Future<List<RemoteEntry>> roots() async =>
      (await _getJson('/v1/fs/roots') as List).map((e) => RemoteEntry.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<RemoteEntry>> list(String path) async => (await _getJson('/v1/fs/list', {'path': path}) as List)
      .map((e) => RemoteEntry.fromJson(e as Map<String, dynamic>))
      .toList();

  /// Downloads [remotePath] into [destination]. The file is written under a
  /// temporary name and only renamed once complete.
  Future<File> download(String remotePath, File destination, {Progress? onProgress}) async {
    if (ble != null) {
      final res = await _bleSend(
        'GET',
        '/v1/fs/download',
        query: {'path': remotePath},
        timeout: const Duration(minutes: 30),
      );
      final partial = File('${destination.path}.sidekick-part');
      await partial.writeAsBytes(res.body, flush: true);
      onProgress?.call(res.body.length, res.body.length);
      return partial.rename(destination.path);
    }
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
    if (ble != null) {
      if (total > bleMaxBody) {
        throw SidekickException('This file is too big for Bluetooth. Connect both devices to the same Wi-Fi.');
      }
      onProgress?.call(0, total);
      final res = await _bleSend(
        'POST',
        '/v1/fs/upload',
        query: query,
        body: await file.readAsBytes(),
        timeout: const Duration(minutes: 30),
      );
      onProgress?.call(total, total);
      return (jsonDecode(utf8.decode(res.body)) as Map<String, dynamic>)['path'] as String;
    }
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
      _noteTls(res);
      final json = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      return json['path'] as String;
    } on HandshakeException {
      throw _tlsFailure();
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
    if (ble != null) {
      throw SidekickException('Remote control needs both devices on the same Wi-Fi. Bluetooth is too slow for it.');
    }
    // Ask first, so a missing permission on the other side comes back as a
    // clear message rather than a failed WebSocket upgrade.
    try {
      await _getJson('/v1/input/status');
    } on SidekickException catch (e) {
      if (e.status != 404) rethrow; // 404: an older Sidekick without the check.
    }
    final channel = IOWebSocketChannel.connect(
      Uri(scheme: 'wss', host: host, port: port, path: '/v1/input'),
      headers: {if (token != null) 'authorization': 'Bearer $token'},
      pingInterval: const Duration(seconds: 10),
      connectTimeout: const Duration(seconds: 4),
      customClient: _http,
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

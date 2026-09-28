import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import '../platform/files.dart';
import '../platform/input.dart';
import '../platform/media.dart';
import 'ble_protocol.dart';
import 'models.dart';
import 'trust.dart';

/// What this device lets paired peers do. Mirrors the toggles in Settings.
class Permissions {
  const Permissions({this.files = true, this.media = true, this.input = true});
  final bool files;
  final bool media;
  final bool input;
}

sealed class ServerEvent {}

/// A device wants to pair; show [request.pin] to the user.
class PairRequested extends ServerEvent {
  PairRequested(this.request);
  final PairingRequest request;
}

/// Pairing finished. [device] is how we reach the new peer.
class Paired extends ServerEvent {
  Paired(this.device);
  final PairedDevice device;
}

class Unpaired extends ServerEvent {
  Unpaired(this.peerId);
  final String peerId;
}

class FileReceived extends ServerEvent {
  FileReceived(this.from, this.file, this.size);
  final TrustedPeer from;
  final File file;
  final int size;
}

/// A peer opened or closed a remote-control session with us.
class RemoteSessionChanged extends ServerEvent {
  RemoteSessionChanged(this.peer, {required this.active});
  final TrustedPeer peer;
  final bool active;
}

/// The HTTP + WebSocket server every Sidekick device runs.
///
/// Unauthenticated routes: `GET /v1/info`, `POST /v1/pair/request`,
/// `POST /v1/pair/confirm`. Everything else needs
/// `Authorization: Bearer <token>` from a paired peer.
class SidekickServer {
  SidekickServer({
    required this.self,
    required this.trust,
    required this.files,
    required this.media,
    required this.input,
    required this.receiveDir,
    Permissions Function()? permissions,
  }) : permissions = permissions ?? (() => const Permissions());

  /// Our own identity; called on every request so name changes apply live.
  final DeviceInfo Function() self;
  final TrustStore trust;
  final FileService files;
  final MediaController media;
  final InputInjector input;
  final Future<String> Function() receiveDir;
  final Permissions Function() permissions;

  final _events = StreamController<ServerEvent>.broadcast();
  Stream<ServerEvent> get events => _events.stream;

  final Map<String, PairingRequest> _pending = {};
  HttpServer? _server;

  int get port => _server?.port ?? 0;

  Future<void> start({int port = sidekickPort, Object? address}) async {
    _server = await shelf_io.serve(handler, address ?? InternetAddress.anyIPv4, port, shared: false);
    _server!.idleTimeout = const Duration(seconds: 30);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Cancels a pairing request, e.g. when the user dismisses the PIN dialog.
  void cancelPairing(String deviceId) => _pending.remove(deviceId)?.cancelled = true;

  /// The request handler, shared by the Wi-Fi (HTTP) server and Bluetooth.
  late final Handler handler = _handler();

  /// Runs a request that arrived over Bluetooth through [handler], so it gets
  /// exactly the same auth, permission checks and behaviour as over Wi-Fi.
  Future<BleResponse> handleBle(BleMessage request) async {
    final h = request.header;
    final query = {for (final e in ((h['query'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
    final uri = Uri(
      scheme: 'http',
      host: 'bluetooth',
      path: (h['path'] as String?) ?? '/',
      queryParameters: query.isEmpty ? null : query,
    );
    final headers = {
      for (final e in ((h['headers'] as Map?) ?? const {}).entries) '${e.key}'.toLowerCase(): '${e.value}',
      'content-length': '${request.body.length}',
    };
    final response = await handler(
      Request(
        ((h['method'] as String?) ?? 'GET').toUpperCase(),
        uri,
        headers: headers,
        body: request.body,
        context: {'sidekick.transport': 'bluetooth'},
      ),
    );
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.read()) {
      body.add(chunk);
      if (body.length > bleMaxBody) throw StateError('Too large for Bluetooth. Use Wi-Fi for big files.');
    }
    return BleResponse(response.statusCode, {
      for (final e in response.headers.entries)
        if (e.key != 'transfer-encoding') e.key: e.value,
    }, body.takeBytes());
  }

  Handler _handler() {
    final router = Router()
      ..get('/v1/info', (Request r) => _json(self().toJson()))
      ..post('/v1/pair/request', _pairRequest)
      ..post('/v1/pair/confirm', _pairConfirm)
      ..post('/v1/unpair', _authed(_unpair))
      ..get('/v1/fs/roots', _authed(_roots, (p) => p.files))
      ..get('/v1/fs/list', _authed(_list, (p) => p.files))
      ..get('/v1/fs/download', _authed(_download, (p) => p.files))
      ..post('/v1/fs/upload', _authed(_upload, (p) => p.files))
      ..get('/v1/media', _authed(_mediaStatus, (p) => p.media))
      ..post('/v1/media', _authed(_mediaAction, (p) => p.media))
      ..get('/v1/input', _authed(_inputSocket, (p) => p.input));
    return const Pipeline().addMiddleware(_errors).addHandler(router.call);
  }

  // -------------------------------------------------------------- helpers

  static Response _json(Object body, {int status = 200}) =>
      Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json'});

  static Response _error(int status, String message) => _json({'error': message}, status: status);

  static Future<Map<String, dynamic>> _body(Request r) async {
    final text = await r.readAsString();
    if (text.length > 64 * 1024) throw const FormatException('Body too large');
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) throw const FormatException('Expected a JSON object');
    return decoded;
  }

  static Handler _errors(Handler inner) => (request) async {
    try {
      return await inner(request);
    } on FormatException catch (e) {
      return _error(400, e.message);
    } on FileSystemException catch (e) {
      return _error(500, e.osError?.message ?? e.message);
    }
  };

  static const _peerKey = 'sidekick.peer';

  /// Wraps [handler] so it only runs for a paired peer that holds the
  /// permission picked by [allowed].
  Handler _authed(Handler handler, [bool Function(Permissions)? allowed]) => (request) {
    final header = request.headers['authorization'] ?? '';
    final token = header.startsWith('Bearer ') ? header.substring(7) : '';
    final peer = token.isEmpty ? null : trust.byToken(token);
    if (peer == null) return _error(401, 'Not paired');
    if (allowed != null && !allowed(permissions())) {
      return _error(403, 'This device has turned that feature off');
    }
    return handler(request.change(context: {_peerKey: peer}));
  };

  static TrustedPeer _peer(Request r) => r.context[_peerKey] as TrustedPeer;

  static String? _remoteAddress(Request r) =>
      (r.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address;

  // -------------------------------------------------------------- pairing

  Future<Response> _pairRequest(Request r) async {
    final body = await _body(r);
    final device = DeviceInfo.fromJson(body['device'] as Map<String, dynamic>, address: _remoteAddress(r));
    if (device.id == self().id) return _error(400, "Can't pair with yourself");
    // A retry while the code is still on screen keeps the same code, and a
    // noisy network can't stack up dialogs.
    if (_pending[device.id]?.isOpen ?? false) return _json({'ok': true, 'device': self().toJson()});
    _pending.removeWhere((_, r) => !r.isOpen);
    if (_pending.length >= 3) return _error(429, 'Too many pairing requests. Try again in a minute.');
    final request = PairingRequest(device);
    _pending[device.id] = request;
    _events.add(PairRequested(request));
    return _json({'ok': true, 'device': self().toJson()});
  }

  /// Body: `{id, pin, token}` where `token` is what the caller wants *us* to
  /// use when we talk to *them*. Returns the token *they* should use with us.
  Future<Response> _pairConfirm(Request r) async {
    final body = await _body(r);
    final id = body['id'];
    final pin = body['pin'];
    final theirToken = body['token'];
    if (id is! String || pin is! String || theirToken is! String || theirToken.length < 32) {
      return _error(400, 'Missing id, pin or token');
    }
    final request = _pending[id];
    if (request == null || !request.isOpen) {
      _pending.remove(id);
      return _error(410, 'No open pairing request. Start pairing again.');
    }
    request.attempts++;
    if (!constantTimeEquals(request.pin, pin)) {
      if (!request.isOpen) _pending.remove(id);
      return _error(403, 'Wrong code');
    }
    _pending.remove(id);

    final ourToken = newToken();
    final device = request.device;
    trust.add(TrustedPeer(id: device.id, name: device.name, platform: device.platform, token: ourToken));
    _events.add(
      Paired(
        PairedDevice(
          id: device.id,
          name: device.name,
          platform: device.platform,
          token: theirToken,
          lastAddress: _remoteAddress(r) ?? device.address,
          lastPort: device.port,
        ),
      ),
    );
    return _json({'token': ourToken, 'device': self().toJson()});
  }

  Response _unpair(Request r) {
    final peer = _peer(r);
    trust.remove(peer.id);
    _events.add(Unpaired(peer.id));
    return _json({'ok': true});
  }

  // -------------------------------------------------------------- files

  Future<Response> _roots(Request r) async => _json((await files.roots()).map((e) => e.toJson()).toList());

  Future<Response> _list(Request r) async {
    final path = r.url.queryParameters['path'];
    if (path == null || path.isEmpty) return _error(400, 'Missing path');
    if (!await Directory(path).exists()) return _error(404, 'Folder not found');
    return _json((await files.list(path)).map((e) => e.toJson()).toList());
  }

  Future<Response> _download(Request r) async {
    final path = r.url.queryParameters['path'];
    if (path == null || path.isEmpty) return _error(400, 'Missing path');
    final file = File(path);
    if (!await file.exists()) return _error(404, 'File not found');
    final length = await file.length();
    final name = p.basename(path);
    return Response.ok(
      file.openRead(),
      headers: {
        'content-type': lookupMimeType(path) ?? 'application/octet-stream',
        'content-length': '$length',
        'content-disposition': "attachment; filename*=UTF-8''${Uri.encodeComponent(name)}",
      },
    );
  }

  /// `POST /v1/fs/upload?name=photo.jpg[&dir=C:\Users\me\Desktop]`, raw bytes
  /// in the body. Without `dir` the file lands in the receive folder.
  Future<Response> _upload(Request r) async {
    final name = sanitizeFileName(r.url.queryParameters['name'] ?? 'file');
    final dirParam = r.url.queryParameters['dir'];
    final dir = (dirParam == null || dirParam.isEmpty) ? await receiveDir() : dirParam;
    if (dirParam != null && dirParam.isNotEmpty && !await Directory(dir).exists()) {
      return _error(404, 'Folder not found');
    }
    await Directory(dir).create(recursive: true);

    // Write to a temporary name, then rename, so a half-sent file never
    // looks complete.
    final partial = File(p.join(dir, '.$name.${newToken().substring(0, 8)}.sidekick-part'));
    var size = 0;
    final sink = partial.openWrite();
    try {
      await sink.addStream(
        r.read().map((chunk) {
          size += chunk.length;
          return chunk;
        }),
      );
      await sink.close();
      final expected = int.tryParse(r.headers['content-length'] ?? '');
      if (expected != null && expected != size) throw const FileSystemException('Upload was cut off');
      final saved = await partial.rename((await uniqueFile(dir, name)).path);
      _events.add(FileReceived(_peer(r), saved, size));
      return _json({'path': saved.path, 'size': size});
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  // -------------------------------------------------------------- media

  Future<Response> _mediaStatus(Request r) async => _json((await media.status()).toJson());

  Future<Response> _mediaAction(Request r) async {
    final body = await _body(r);
    final action = MediaAction.values.where((a) => a.name == body['action']).firstOrNull;
    if (action == null) return _error(400, 'Unknown action');
    final positionMs = body['positionMs'];
    final volume = body['volume'];
    await media.perform(
      action,
      position: positionMs is num ? Duration(milliseconds: positionMs.toInt()) : null,
      volume: volume is num ? volume.toDouble() : null,
    );
    return _json({'ok': true});
  }

  // -------------------------------------------------------------- input

  FutureOr<Response> _inputSocket(Request r) {
    final peer = _peer(r);
    return webSocketHandler((channel, _) {
      _events.add(RemoteSessionChanged(peer, active: true));
      channel.stream.listen(
        (data) {
          // Stop obeying the moment the peer is unpaired.
          if (trust.byId(peer.id)?.token != peer.token) {
            channel.sink.close();
            return;
          }
          if (data is! String) return;
          try {
            final msg = jsonDecode(data);
            if (msg is Map<String, dynamic>) handleInputMessage(input, msg);
          } catch (_) {
            // Ignore malformed messages.
          }
        },
        onDone: () => _events.add(RemoteSessionChanged(peer, active: false)),
        cancelOnError: true,
      );
    }, pingInterval: const Duration(seconds: 10))(r);
  }
}

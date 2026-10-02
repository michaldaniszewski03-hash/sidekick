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
import '../platform/hotspot.dart';
import '../platform/input.dart';
import 'ble_protocol.dart';
import 'crypto.dart';
import 'models.dart';
import 'trust.dart';

/// What this device lets paired peers do. Mirrors the toggles in Settings.
class Permissions {
  const Permissions({this.files = true, this.input = true});
  final bool files;
  final bool input;

  Permissions copyWith({bool? files, bool? input}) =>
      Permissions(files: files ?? this.files, input: input ?? this.input);
}

sealed class ServerEvent {}

/// A device wants to pair; show [request.pin] to the user.
class PairRequested extends ServerEvent {
  PairRequested(this.request);
  final PairingRequest request;
}

/// A device scanned our QR code and is pairing with it; no code to show.
class InviteScanned extends ServerEvent {
  InviteScanned(this.device);
  final DeviceInfo device;
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
  FileReceived(this.from, this.file, this.size, this.security, {this.toReceiveFolder = false});
  final TrustedPeer from;
  final File file;
  final int size;
  final TransferSecurity security;

  /// Sent to this device (into the receive folder), not copied into a
  /// folder someone picked while browsing its files.
  final bool toReceiveFolder;
}

/// A paired device wants to send files here. Show [offer] and answer it;
/// it closes by itself if the sender gives up or nobody answers in time.
class TransferOffered extends ServerEvent {
  TransferOffered(this.offer);
  final TransferOffer offer;
}

/// A file announced in a [TransferOffer].
class OfferedFile {
  const OfferedFile(this.name, this.size);
  final String name;
  final int size;
}

enum OfferAnswer { accepted, declined, cancelled, timedOut }

/// Files a paired device asked to send. Accepting gives the sender a
/// ticket, and uploads to the receive folder need one.
class TransferOffer {
  TransferOffer({required this.id, required this.from, required this.files});
  final String id;
  final TrustedPeer from;
  final List<OfferedFile> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);

  final _answer = Completer<OfferAnswer>();
  final _progress = StreamController<int>.broadcast();
  int received = 0;
  int filesReceived = 0;

  /// How it was answered (or why it closed without an answer).
  Future<OfferAnswer> get answer => _answer.future;
  bool get isOpen => !_answer.isCompleted;

  /// Bytes received so far, once accepted. Closes when every file is in.
  Stream<int> get progress => _progress.stream;
  bool get complete => filesReceived >= files.length;

  void accept() => _close(OfferAnswer.accepted);
  void decline() => _close(OfferAnswer.declined);

  void _close(OfferAnswer answer) {
    if (!_answer.isCompleted) _answer.complete(answer);
  }

  /// Sizes of the files already in.
  int _doneBytes = 0;

  void _addReceived(int bytes) {
    // Bluetooth counts raw bytes (a little more than the file: headers,
    // encryption), so never past what was announced.
    received = (received + bytes).clamp(0, totalBytes);
    if (!_progress.isClosed) _progress.add(received);
  }

  /// Lets the screenshot tool (tool/ad_frames_test.dart) show a transfer
  /// in progress without one: [bytes] received, or a file finished.
  void debugReceived(int bytes, {bool fileDone = false}) => fileDone ? _fileDone(bytes) : _addReceived(bytes);

  void _fileDone(int size) {
    filesReceived++;
    _doneBytes += size;
    received = _doneBytes.clamp(0, totalBytes);
    if (!_progress.isClosed) _progress.add(received);
    if (complete) _progress.close();
  }
}

class _Ticket {
  _Ticket(this.peerId, this.offer) : expires = DateTime.now().add(const Duration(minutes: 30));
  final String peerId;
  final TransferOffer offer;
  final DateTime expires;
  int uses = 0;
}

/// A file arriving in parts (`/v1/fs/upload/part`).
class _PartUpload {
  _PartUpload({
    required this.peerId,
    required this.name,
    required this.dir,
    required this.total,
    required this.ticket,
    required this.partial,
    required this.toReceiveFolder,
  });
  final String peerId;
  final String name;
  final String dir;
  final bool toReceiveFolder;
  final int total;
  final _Ticket? ticket;
  final File partial;
  int received = 0;
  DateTime touched = DateTime.now();
}

/// A peer tried remote control, but this device can't accept it yet (e.g.
/// the Mac's Accessibility permission is missing).
class InputBlocked extends ServerEvent {
  InputBlocked(this.peer);
  final TrustedPeer peer;
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
    required this.identity,
    required this.self,
    required this.trust,
    required this.files,
    required this.input,
    required this.receiveDir,
    Permissions Function()? permissions,
    DirectLink? link,
    Future<bool> Function()? inputReady,
    bool Function()? askBeforeReceiving,
  }) : askBeforeReceiving = askBeforeReceiving ?? (() => true),
       inputReady = inputReady ?? (() async => input.supported),
       permissions = permissions ?? (() => const Permissions()),
       link = link ?? NoDirectLink();

  /// Our certificate and key: the server only speaks HTTPS.
  final Identity identity;

  /// Our own identity; called on every request so name changes apply live.
  final DeviceInfo Function() self;
  final TrustStore trust;
  final FileService files;
  final InputInjector input;
  final Future<String> Function() receiveDir;
  final Permissions Function() permissions;

  /// Whether we can inject input right now. Re-checks the OS permission, so
  /// granting it takes effect without restarting.
  final Future<bool> Function() inputReady;

  /// Opens or joins a direct Wi-Fi link when a peer asks over Bluetooth.
  final DirectLink link;

  /// Whether files sent here wait for the user to accept them.
  final bool Function() askBeforeReceiving;

  /// How long an offer waits for an answer.
  static const offerTimeout = Duration(seconds: 60);

  final Map<String, TransferOffer> _offers = {};
  final Map<String, _Ticket> _tickets = {};

  final _events = StreamController<ServerEvent>.broadcast();
  Stream<ServerEvent> get events => _events.stream;

  final Map<String, PairingRequest> _pending = {};
  PairingInvite? _invite;
  HttpServer? _server;

  int get port => _server?.port ?? 0;

  Future<void> start({int port = sidekickPort, Object? address}) async {
    _server = await shelf_io.serve(
      handler,
      address ?? InternetAddress.anyIPv4,
      port,
      shared: false,
      securityContext: identity.serverContext(),
    );
    _server!.idleTimeout = const Duration(seconds: 30);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Cancels a pairing request, e.g. when the user dismisses the PIN dialog.
  void cancelPairing(String deviceId) => _pending.remove(deviceId)?.cancelled = true;

  /// A new QR code invitation (the previous one stops working).
  PairingInvite createInvite() {
    _invite?.cancelled = true;
    return _invite = PairingInvite();
  }

  /// The QR code was closed: nobody can pair with it any more.
  void cancelInvite(PairingInvite invite) {
    invite.cancelled = true;
    if (identical(_invite, invite)) _invite = null;
    for (final request in _pending.values) {
      if (identical(request.invite, invite)) request.cancelled = true;
    }
  }

  /// The request handler, shared by the Wi-Fi (HTTP) server and Bluetooth.
  late final Handler handler = _handler();

  /// Bytes arriving over Bluetooth from a paired device: counted toward the
  /// files it's sending, so the receiving screen moves as they come in.
  void bleReceiving(String peerId, int bytes) {
    final now = DateTime.now();
    for (final t in _tickets.values) {
      if (t.peerId == peerId && now.isBefore(t.expires) && !t.offer.complete) {
        t.offer._addReceived(bytes);
        return;
      }
    }
  }

  /// The pairing key a peer seals its Bluetooth requests with.
  Uint8List? bleKeyFor(String peerId) {
    final peer = trust.byId(peerId);
    return peer == null ? null : base64.decode(peer.key);
  }

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
        context: {'sidekick.transport': 'bluetooth', 'sidekick.sealedBy': ?h['sealedBy'] as String?},
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
      ..post('/v1/pair/start', _pairStart)
      ..post('/v1/pair/confirm', _pairConfirm)
      ..post('/v1/unpair', _authed(_unpair))
      ..get('/v1/fs/roots', _authed(_roots, (p) => p.files))
      ..get('/v1/fs/list', _authed(_list, (p) => p.files))
      ..get('/v1/fs/download', _authed(_download, (p) => p.files))
      ..post('/v1/fs/upload', _authed(_upload, (p) => p.files))
      ..post('/v1/fs/upload/part', _authed(_uploadPart, (p) => p.files))
      ..post('/v1/transfer/offer', _authed(_offer, (p) => p.files))
      ..post('/v1/transfer/cancel', _authed(_cancelOffer, (p) => p.files))
      ..get('/v1/input/status', _authed(_inputStatus, (p) => p.input))
      ..get('/v1/input', _authed(_inputSocket, (p) => p.input))
      ..post('/v1/link/hotspot', _authed(_linkHotspot))
      ..post('/v1/link/join', _authed(_linkJoin))
      ..post('/v1/link/release', _authed(_linkRelease));
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
    // Over Bluetooth there's no TLS: paired traffic must be sealed with the
    // key from pairing, by the same peer the token belongs to.
    if (request.context['sidekick.transport'] == 'bluetooth' && request.context['sidekick.sealedBy'] != peer.id) {
      return _error(401, 'Bluetooth requests must be encrypted');
    }
    if (allowed != null && !allowed(permissions())) {
      return _error(403, 'This device has turned that feature off');
    }
    return handler(request.change(context: {_peerKey: peer}));
  };

  static TrustedPeer _peer(Request r) => r.context[_peerKey] as TrustedPeer;

  static String? _remoteAddress(Request r) =>
      (r.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address;

  // -------------------------------------------------------------- pairing

  /// Body: `{device, fingerprint, invite?}`. Shows a PIN on this device, or
  /// with `invite: true` (the requester scanned our QR code) uses the QR
  /// code's secret instead. Returns our identity and certificate fingerprint.
  Future<Response> _pairRequest(Request r) async {
    final body = await _body(r);
    final device = DeviceInfo.fromJson(body['device'] as Map<String, dynamic>, address: _remoteAddress(r));
    final fingerprint = body['fingerprint'];
    if (fingerprint is! String || fingerprint.length != 64) {
      return _error(426, 'Update Sidekick on the other device: this version needs encrypted pairing.');
    }
    if (device.id == self().id) return _error(400, "Can't pair with yourself");
    final reply = {'ok': true, 'device': self().toJson(), 'fingerprint': identity.fingerprint};
    // A retry while the code is still on screen keeps the same code, and a
    // noisy network can't stack up dialogs.
    final viaInvite = body['invite'] == true;
    final existing = _pending[device.id];
    if (existing != null &&
        existing.isOpen &&
        existing.fingerprint == fingerprint &&
        (existing.invite != null) == viaInvite) {
      return _json(reply);
    }
    final invite = _invite;
    if (viaInvite && (invite == null || !invite.isOpen)) {
      return _error(410, 'That QR code has expired. Show a new one and scan again.');
    }
    _pending.removeWhere((_, r) => !r.isOpen);
    if (_pending.length >= 3 && existing == null) {
      return _error(429, 'Too many pairing requests. Try again in a minute.');
    }
    existing?.cancelled = true;
    final request = PairingRequest(device, fingerprint: fingerprint, invite: viaInvite ? invite : null);
    _pending[device.id] = request;
    _events.add(viaInvite ? InviteScanned(device) : PairRequested(request));
    return _json(reply);
  }

  /// SPAKE2, our half. Body: `{id, msg}`. Each round uses up one of the
  /// request's attempts, so the PIN can only be guessed online, 5 times.
  Future<Response> _pairStart(Request r) async {
    final body = await _body(r);
    final id = body['id'];
    final msg = body['msg'];
    if (id is! String || msg is! String) return _error(400, 'Missing id or msg');
    final request = _pending[id];
    if (request == null || !request.isOpen) {
      _pending.remove(id);
      return _error(410, 'No open pairing request. Start pairing again.');
    }
    request.attempts++;
    final context = pairingContext(
      idA: request.device.id,
      fingerprintA: request.fingerprint,
      idB: self().id,
      fingerprintB: identity.fingerprint,
    );
    final spake = Spake2(isA: false, pin: request.pin, context: context);
    request
      ..keys = spake.finish(base64.decode(msg))
      ..context = context;
    return _json({'msg': base64.encode(spake.message)});
  }

  /// Body: `{id, confirm, token}`. [confirm] proves the caller derived the
  /// same key (so it knew the PIN and saw our real certificate); `token`,
  /// sealed with that key, is what we use when we talk to *them*. Returns
  /// our proof and the (sealed) token *they* should use with us.
  Future<Response> _pairConfirm(Request r) async {
    final body = await _body(r);
    final id = body['id'];
    final confirm = body['confirm'];
    final sealedToken = body['token'];
    if (id is! String || confirm is! String || sealedToken is! String) {
      return _error(400, 'Missing id, confirm or token');
    }
    final request = _pending[id];
    final keys = request?.keys;
    final context = request?.context;
    // The last allowed attempt still gets its proof checked, so only look at
    // cancel and expiry here.
    if (request == null ||
        keys == null ||
        context == null ||
        request.cancelled ||
        DateTime.now().isAfter(request.expires)) {
      return _error(410, 'No open pairing request. Start pairing again.');
    }
    // One proof per SPAKE2 round.
    request
      ..keys = null
      ..context = null;
    if (!tagsEqual(confirmTag(keys.confirmA, context), confirm)) {
      if (!request.isOpen) _pending.remove(id);
      return _error(403, 'Wrong code');
    }
    final String theirToken;
    try {
      theirToken = utf8.decode(unseal(keys.linkKey, base64.decode(sealedToken), aad: utf8.encode('token A')));
    } on FormatException {
      return _error(403, 'Wrong code');
    }
    if (theirToken.length < 32) return _error(400, 'Token too short');
    _pending.remove(id);
    // A QR code pairs one device.
    final invite = request.invite;
    if (invite != null) {
      invite.used = true;
      if (identical(_invite, invite)) _invite = null;
    }

    final ourToken = newToken();
    final device = request.device;
    final key = base64.encode(keys.linkKey);
    trust.add(
      TrustedPeer(
        id: device.id,
        name: device.name,
        platform: device.platform,
        token: ourToken,
        fingerprint: request.fingerprint,
        key: key,
      ),
    );
    _events.add(
      Paired(
        PairedDevice(
          id: device.id,
          name: device.name,
          platform: device.platform,
          token: theirToken,
          fingerprint: request.fingerprint,
          key: key,
          lastAddress: _remoteAddress(r) ?? device.address,
          lastPort: device.port,
        ),
      ),
    );
    return _json({
      'confirm': confirmTag(keys.confirmB, context),
      'token': base64.encode(sealBytes(keys.linkKey, utf8.encode(ourToken), aad: utf8.encode('token B'))),
      'device': self().toJson(),
    });
  }

  Response _unpair(Request r) {
    final peer = _peer(r);
    trust.remove(peer.id);
    _events.add(Unpaired(peer.id));
    return _json({'ok': true});
  }

  // -------------------------------------------------------------- direct link

  static bool _overBluetooth(Request r) => r.context['sidekick.transport'] == 'bluetooth';

  /// Opens a hotspot for the asking peer and returns how to join it. Only
  /// over Bluetooth: on a shared network there's no point.
  Future<Response> _linkHotspot(Request r) async {
    if (!_overBluetooth(r)) return _error(400, 'Already on the same network');
    if (!link.canHost) return _error(501, "This device can't open a hotspot");
    try {
      return _json((await link.host()).toJson());
    } on DirectLinkException catch (e) {
      return _error(503, e.message);
    }
  }

  /// Joins the asking peer's hotspot and returns its addresses we reach.
  Future<Response> _linkJoin(Request r) async {
    if (!_overBluetooth(r)) return _error(400, 'Already on the same network');
    if (!link.canJoin) return _error(501, "This device can't join a hotspot");
    final creds = HotspotCredentials.fromJson(await _body(r));
    try {
      return _json({'addresses': await link.join(creds)});
    } on DirectLinkException catch (e) {
      return _error(503, e.message);
    }
  }

  /// The peer is done: close our hotspot, or go back to our usual network.
  Future<Response> _linkRelease(Request r) async {
    // Answer first; leaving the network may cut this very connection.
    Timer(const Duration(milliseconds: 300), () {
      unawaited(link.stopHosting());
      unawaited(link.leave());
    });
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

  /// `POST /v1/transfer/offer`, body `{id, files: [{name, size}]}`: asks
  /// the user here to accept files, and waits (up to [offerTimeout]) for
  /// the answer: `{accepted, ticket?, answer}`. Uploads to the receive
  /// folder then carry the ticket.
  Future<Response> _offer(Request r) async {
    final body = await _body(r);
    final id = body['id'];
    final list = body['files'];
    if (id is! String || id.isEmpty || id.length > 64 || list is! List || list.isEmpty || list.length > 1000) {
      return _error(400, 'Bad offer');
    }
    final files = [
      for (final f in list.whereType<Map>())
        OfferedFile(sanitizeFileName('${f['name'] ?? 'file'}'), (f['size'] as num?)?.toInt() ?? 0),
    ];
    final peer = _peer(r);
    _offers.removeWhere((_, o) => !o.isOpen);
    if (_offers.values.where((o) => o.from.id == peer.id).length >= 3) {
      return _error(429, 'Too many offers waiting. Try again in a minute.');
    }
    final offer = TransferOffer(id: id, from: peer, files: files);
    if (askBeforeReceiving()) {
      _offers[id] = offer;
      _events.add(TransferOffered(offer));
      Timer(offerTimeout, () => offer._close(OfferAnswer.timedOut));
    } else {
      offer.accept();
    }
    final answer = await offer.answer;
    _offers.remove(id);
    if (answer != OfferAnswer.accepted) return _json({'accepted': false, 'answer': answer.name});
    _tickets.removeWhere((_, t) => DateTime.now().isAfter(t.expires));
    final ticket = newToken();
    _tickets[ticket] = _Ticket(peer.id, offer);
    return _json({'accepted': true, 'answer': answer.name, 'ticket': ticket});
  }

  /// `POST /v1/transfer/cancel`, body `{id}`: the sender stopped waiting.
  Future<Response> _cancelOffer(Request r) async {
    final id = (await _body(r))['id'];
    final offer = _offers[id];
    if (offer != null && offer.from.id == _peer(r).id) offer._close(OfferAnswer.cancelled);
    return _json({'ok': true});
  }

  /// Files sent to the receive folder need a ticket from an accepted offer
  /// (a paired device browsing a folder already has full file access). Uses
  /// up one of the ticket's files.
  (_Ticket?, Response?) _takeTicket(Request r, String? dirParam) {
    if (dirParam != null && dirParam.isNotEmpty) return (null, null);
    var ticket = _tickets[r.url.queryParameters['ticket'] ?? ''];
    final valid =
        ticket != null &&
        ticket.peerId == _peer(r).id &&
        DateTime.now().isBefore(ticket.expires) &&
        ticket.uses < ticket.offer.files.length;
    if (!valid) {
      if (askBeforeReceiving()) {
        return (
          null,
          _error(403, '${self().name} asks before receiving files. Update Sidekick on this device and send again.'),
        );
      }
      ticket = null;
    }
    ticket?.uses++;
    return (ticket, null);
  }

  /// Uploads arriving in parts (see [_uploadPart]), by upload id.
  final Map<String, _PartUpload> _partUploads = {};

  /// `POST /v1/fs/upload/part?name=…&upload=<id>&offset=<n>&total=<n>[&dir=…][&ticket=…]`,
  /// one piece of a file. Bluetooth sends files this way: each part is
  /// sealed and checked on its own, so one damaged packet costs a resend of
  /// that part instead of the whole file. Parts must come in order; a part
  /// that was already stored (a retry) is simply acknowledged. Answers
  /// `{received}` until the last part, then `{path, size}`.
  Future<Response> _uploadPart(Request r) async {
    final q = r.url.queryParameters;
    final id = q['upload'] ?? '';
    final offset = int.tryParse(q['offset'] ?? '');
    final total = int.tryParse(q['total'] ?? '');
    if (id.isEmpty || id.length > 64 || offset == null || offset < 0 || total == null || total < 0) {
      return _error(400, 'Bad upload part');
    }
    final body = await r
        .read()
        .fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c))
        .then((b) => b.takeBytes());

    // Uploads nobody finished within 10 minutes are dropped.
    final now = DateTime.now();
    for (final stale in _partUploads.entries.where((e) => now.difference(e.value.touched).inMinutes >= 10).toList()) {
      _partUploads.remove(stale.key);
      stale.value.ticket?.offer._fileDone(0);
      await stale.value.partial.delete().catchError((_) => stale.value.partial);
    }

    var up = _partUploads[id];
    if (up != null && up.peerId != _peer(r).id) return _error(403, 'Not your upload');
    if (up == null) {
      if (offset != 0) return _error(409, 'The transfer was interrupted. Send it again.');
      final dirParam = q['dir'];
      final dir = (dirParam == null || dirParam.isEmpty) ? await receiveDir() : dirParam;
      if (dirParam != null && dirParam.isNotEmpty && !await Directory(dir).exists()) {
        return _error(404, 'Folder not found');
      }
      final (ticket, refusal) = _takeTicket(r, dirParam);
      if (refusal != null) return refusal;
      await Directory(dir).create(recursive: true);
      final name = sanitizeFileName(q['name'] ?? 'file');
      up = _partUploads[id] = _PartUpload(
        peerId: _peer(r).id,
        name: name,
        dir: dir,
        total: total,
        ticket: ticket,
        partial: File(p.join(dir, '.$name.${newToken().substring(0, 8)}.sidekick-part')),
        toReceiveFolder: dirParam == null || dirParam.isEmpty,
      );
      await up.partial.writeAsBytes(const [], flush: true);
    }
    up.touched = now;

    // In order: a retry of a stored part, or a gap, just reports where we are.
    if (offset == up.received && body.isNotEmpty) {
      if (up.received + body.length > up.total) {
        await _dropPartUpload(id, up);
        return _error(400, 'More data than announced');
      }
      try {
        await up.partial.writeAsBytes(body, mode: FileMode.append, flush: true);
      } catch (e) {
        await _dropPartUpload(id, up);
        rethrow;
      }
      up.received += body.length;
    }
    if (up.received < up.total) return _json({'received': up.received});

    _partUploads.remove(id);
    final saved = await up.partial.rename((await uniqueFile(up.dir, up.name)).path);
    final security = _overBluetooth(r)
        ? const TransferSecurity.bluetooth()
        : TransferSecurity.wifi(certificate: _peer(r).fingerprint);
    up.ticket?.offer._fileDone(up.total);
    _events.add(FileReceived(_peer(r), saved, up.total, security, toReceiveFolder: up.toReceiveFolder));
    return _json({'path': saved.path, 'size': up.total, 'received': up.total});
  }

  Future<void> _dropPartUpload(String id, _PartUpload up) async {
    _partUploads.remove(id);
    up.ticket?.offer._fileDone(0);
    if (await up.partial.exists()) await up.partial.delete();
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
    final (ticket, refusal) = _takeTicket(r, dirParam);
    if (refusal != null) return refusal;
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
          // Over Bluetooth, [bleReceiving] already counted it on arrival.
          if (!_overBluetooth(r)) ticket?.offer._addReceived(chunk.length);
          return chunk;
        }),
      );
      await sink.close();
      final expected = int.tryParse(r.headers['content-length'] ?? '');
      if (expected != null && expected != size) throw const FileSystemException('Upload was cut off');
      final saved = await partial.rename((await uniqueFile(dir, name)).path);
      // Over Bluetooth, _authed only lets sealed requests through; everything
      // else arrived over this TLS-only server.
      final security = _overBluetooth(r)
          ? const TransferSecurity.bluetooth()
          : TransferSecurity.wifi(certificate: _peer(r).fingerprint);
      ticket?.offer._fileDone(size);
      _events.add(FileReceived(_peer(r), saved, size, security, toReceiveFolder: dirParam == null || dirParam.isEmpty));
      return _json({'path': saved.path, 'size': size});
    } catch (_) {
      // Counts as finished, so the receiving screen doesn't wait for it.
      ticket?.offer._fileDone(0);
      await sink.close().catchError((_) {});
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  // -------------------------------------------------------------- input

  /// Checked before opening the input socket, so the controlling device can
  /// say *why* remote control doesn't work instead of a generic failure.
  Future<Response> _inputStatus(Request r) async {
    if (await inputReady()) return _json({'ok': true});
    _events.add(InputBlocked(_peer(r)));
    final me = self();
    final where = switch (me.platform) {
      DevicePlatform.macos => 'Settings → Accessibility',
      DevicePlatform.android => 'Settings → Remote control (Accessibility)',
      _ => 'Settings',
    };
    return _error(503, "${me.name} hasn't allowed remote control yet. On ${me.name}, open Sidekick → $where.");
  }

  FutureOr<Response> _inputSocket(Request r) async {
    if (!await inputReady()) return _error(503, "This device hasn't allowed remote control yet.");
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

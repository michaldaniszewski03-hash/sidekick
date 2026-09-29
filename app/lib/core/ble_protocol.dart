/// How Sidekick talks over Bluetooth LE, independent of any Bluetooth API so
/// it can be unit-tested.
///
/// Each device offers one GATT service with three characteristics:
///   info  (read)   this device's [DeviceInfo] as JSON
///   rx    (write)  request chunks from the connected device
///   tx    (notify) response chunks back to it
///
/// A request or response is a *message*: a 4-byte big-endian header length,
/// a JSON header, then the body bytes. Messages are cut into chunks that fit
/// one Bluetooth packet: [flags][message id: 2 bytes][payload], where flag
/// bit 0 marks the last chunk. Requests carry the same method/path/query as
/// the HTTP API, so the Bluetooth server simply runs them through the
/// regular request handler.
///
/// Between paired devices every message is *sealed*: the real message is
/// encrypted with AES-256-GCM under the key from pairing and carried as the
/// body of an outer message whose header only says who sealed it. Requests
/// carry a timestamp and responses echo the request's nonce, so recorded
/// traffic can't be replayed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' show UUID;

import 'crypto.dart';

final bleServiceUuid = UUID.fromString('7c3e9a52-8b1f-4c2d-9e6a-3f5d1b2c4a00');
final bleRxUuid = UUID.fromString('7c3e9a52-8b1f-4c2d-9e6a-3f5d1b2c4a01');
final bleTxUuid = UUID.fromString('7c3e9a52-8b1f-4c2d-9e6a-3f5d1b2c4a02');
final bleInfoUuid = UUID.fromString('7c3e9a52-8b1f-4c2d-9e6a-3f5d1b2c4a03');

/// The name iPhones and Macs advertise, so they can be recognized even when
/// a scanner doesn't get the service id.
const bleAdvertisedName = 'Sidekick';

/// Bytes of chunk overhead: flags + message id.
const bleChunkHeader = 3;

/// Bluetooth is slow (tens of KB/s), so refuse transfers that would take
/// forever; Wi-Fi handles those.
const bleMaxBody = 50 * 1024 * 1024;

const _last = 0x01;

/// Encodes a message: header length, JSON header, body.
Uint8List encodeMessage(Map<String, Object?> header, [List<int> body = const []]) {
  final head = utf8.encode(jsonEncode(header));
  final out = BytesBuilder(copy: false)
    ..add((ByteData(4)..setUint32(0, head.length)).buffer.asUint8List())
    ..add(head)
    ..add(body);
  return out.takeBytes();
}

/// Splits a message into chunks of at most [maxChunk] bytes.
List<Uint8List> chunkMessage(int id, Uint8List message, int maxChunk) {
  final payload = maxChunk - bleChunkHeader;
  if (payload < 1) throw ArgumentError('maxChunk too small: $maxChunk');
  final chunks = <Uint8List>[];
  var offset = 0;
  do {
    final end = (offset + payload).clamp(0, message.length);
    final last = end >= message.length;
    final chunk = Uint8List(bleChunkHeader + end - offset)
      ..[0] = last ? _last : 0
      ..[1] = (id >> 8) & 0xff
      ..[2] = id & 0xff
      ..setRange(bleChunkHeader, bleChunkHeader + end - offset, message, offset);
    chunks.add(chunk);
    offset = end;
  } while (offset < message.length);
  return chunks;
}

/// Decodes a whole message (see [encodeMessage]).
BleMessage decodeMessage(int id, Uint8List bytes) {
  if (bytes.length < 4) throw const FormatException('Message too short');
  final headLength = ByteData.sublistView(bytes, 0, 4).getUint32(0);
  if (4 + headLength > bytes.length) throw const FormatException('Bad header length');
  final header = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 4, 4 + headLength)));
  if (header is! Map<String, dynamic>) throw const FormatException('Header must be an object');
  return BleMessage(id, header, Uint8List.sublistView(bytes, 4 + headLength));
}

/// Who seals a request, and with which key (from pairing).
class BleSeal {
  const BleSeal({required this.senderId, required this.key});
  final String senderId;
  final Uint8List key;
}

List<int> _aad(String kind, int id) => utf8.encode('sidekick-ble $kind $id');

String _nonceOf(Uint8List sealed) => base64.encode(sealed.sublist(0, 12));

/// How far a sealed request's clock may be off before we refuse it.
const _maxSkew = Duration(minutes: 2);

/// A decoded message.
class BleMessage {
  BleMessage(this.id, this.header, this.body);
  final int id;
  final Map<String, dynamic> header;
  final Uint8List body;
}

/// Reassembles chunks (possibly from interleaved messages) into messages.
class BleReassembler {
  final Map<int, BytesBuilder> _parts = {};

  /// Returns the finished message when [chunk] is its last piece.
  BleMessage? add(Uint8List chunk) {
    if (chunk.length < bleChunkHeader) throw const FormatException('Chunk too short');
    final id = (chunk[1] << 8) | chunk[2];
    final builder = _parts.putIfAbsent(id, () => BytesBuilder(copy: true))
      ..add(Uint8List.sublistView(chunk, bleChunkHeader));
    if (builder.length > bleMaxBody + 64 * 1024) {
      _parts.remove(id);
      throw const FormatException('Message too large for Bluetooth');
    }
    if (chunk[0] & _last == 0) return null;
    _parts.remove(id);
    return decodeMessage(id, builder.takeBytes());
  }

  void clear() => _parts.clear();
}

/// A response to a Bluetooth request.
class BleResponse {
  BleResponse(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
}

/// The client side of the protocol over any "link" that can send chunks and
/// delivers incoming chunks. Real links wrap a Bluetooth connection; tests
/// use an in-memory one.
class BleRpcClient {
  BleRpcClient({required this.send, required Stream<Uint8List> incoming, required this.chunkSize}) {
    _sub = incoming.listen(_onChunk, onDone: _fail, onError: (Object _) => _fail());
  }

  /// Sends one chunk; must complete when the chunk is on its way.
  final Future<void> Function(Uint8List chunk) send;

  /// Largest chunk the link carries right now (it can grow once the
  /// connection negotiates a bigger MTU).
  final Future<int> Function() chunkSize;

  late final StreamSubscription<Uint8List> _sub;
  final _reassembler = BleReassembler();
  final Map<int, _Pending> _pending = {};
  int _nextId = 1;
  Future<void> _sending = Future.value();

  void _onChunk(Uint8List chunk) {
    try {
      var msg = _reassembler.add(chunk);
      if (msg == null) return;
      final pending = _pending[msg.id];
      if (pending == null) return;
      final seal = pending.seal;
      if (seal != null) {
        if (msg.header['sealed'] == true) {
          // A sealed answer must answer *this* request.
          msg = decodeMessage(msg.id, unseal(seal.key, msg.body, aad: _aad('res', msg.id)));
          if (msg.header['rn'] != pending.nonce) return;
        } else if (((msg.header['status'] as num?)?.toInt() ?? 200) < 400) {
          // Unsealed is only believable as a refusal (e.g. we're not paired
          // any more), never as data.
          return;
        }
      }
      final headers = <String, String>{
        for (final e in ((msg.header['headers'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}',
      };
      _pending.remove(msg.id);
      pending.completer.complete(BleResponse((msg.header['status'] as num?)?.toInt() ?? 500, headers, msg.body));
    } on FormatException {
      // A garbled or forged response; the request will time out.
    }
  }

  void _fail() {
    for (final p in _pending.values) {
      if (!p.completer.isCompleted) p.completer.completeError(StateError('Bluetooth connection lost'));
    }
    _pending.clear();
  }

  Future<BleResponse> request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    List<int> body = const [],
    Duration timeout = const Duration(seconds: 30),
    BleSeal? seal,
    void Function(int sent, int total)? onSent,
  }) async {
    if (body.length > bleMaxBody) throw StateError('Too large to send over Bluetooth. Use Wi-Fi for big files.');
    final id = _nextId;
    _nextId = _nextId >= 0xffff ? 1 : _nextId + 1;
    final completer = Completer<BleResponse>();
    final header = {'method': method, 'path': path, 'query': ?query, 'headers': ?headers};
    Uint8List message;
    String? nonce;
    if (seal == null) {
      message = encodeMessage(header, body);
    } else {
      final inner = encodeMessage({...header, 'ts': DateTime.now().millisecondsSinceEpoch}, body);
      final sealed = sealBytes(seal.key, inner, aad: _aad('req', id));
      nonce = _nonceOf(sealed);
      message = encodeMessage({'sealed': seal.senderId}, sealed);
    }
    _pending[id] = _Pending(completer, seal, nonce);
    // Chunks of one message must not interleave with another's writes.
    final sent = _sending.then((_) async {
      var sent = 0;
      for (final chunk in chunkMessage(id, message, await chunkSize())) {
        await send(chunk);
        sent += chunk.length - bleChunkHeader;
        onSent?.call(sent, message.length);
      }
    });
    _sending = sent.catchError((_) {});
    try {
      await sent;
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> close() async {
    await _sub.cancel();
    _fail();
  }
}

/// The server side: turns incoming request chunks into ordinary HTTP-style
/// requests for [handler] (the same one the Wi-Fi server uses, so pairing,
/// auth and permissions behave identically) and chunks the responses back.
class BleRequestDispatcher {
  BleRequestDispatcher(this.handler, {Uint8List? Function(String peerId)? keyFor, this.onReceiving})
    : keyFor = keyFor ?? ((_) => null);

  final Future<BleResponse> Function(BleMessage request) handler;

  /// Bytes arriving from a paired device, as they come in (a big request
  /// only reaches [handler] once it's all here). Known once a device has
  /// sent one sealed request over this connection.
  final void Function(String peerId, int bytes)? onReceiving;

  /// Which paired device each connection belongs to.
  final Map<String, String> _peerOf = {};

  /// The pairing key for a peer id, or null if we're not paired.
  final Uint8List? Function(String peerId) keyFor;
  final Map<String, BleReassembler> _peers = {};

  /// Nonces of recent sealed requests, to refuse replays.
  final Map<String, DateTime> _seen = {};

  /// Feeds a chunk from [peer]. When it completes a request, runs it and
  /// sends the response through [sendChunk].
  Future<void> onChunk(
    String peer,
    Uint8List chunk, {
    required Future<void> Function(Uint8List chunk) sendChunk,
    required int maxChunk,
  }) async {
    final sender = _peerOf[peer];
    if (sender != null && chunk.length > bleChunkHeader) onReceiving?.call(sender, chunk.length - bleChunkHeader);
    final BleMessage? request;
    try {
      request = _peers.putIfAbsent(peer, BleReassembler.new).add(chunk);
    } on FormatException {
      _peers.remove(peer);
      return;
    }
    if (request == null) return;
    final id = request.id;
    Uint8List? key;
    String? nonce;
    BleResponse response;
    try {
      final BleMessage inner;
      final sealedBy = request.header['sealed'];
      if (sealedBy is String) {
        key = keyFor(sealedBy);
        if (key == null) throw const _Refused(401, 'Not paired');
        final Uint8List plain;
        try {
          plain = unseal(key, request.body, aad: _aad('req', id));
        } on FormatException {
          key = null; // Don't answer with a key the sender may not have.
          throw const _Refused(401, 'Message failed authentication');
        }
        nonce = _nonceOf(request.body);
        final message = decodeMessage(id, plain);
        final ts = DateTime.fromMillisecondsSinceEpoch((message.header['ts'] as num?)?.toInt() ?? 0);
        final now = DateTime.now();
        _seen.removeWhere((_, t) => now.difference(t) > _maxSkew * 2);
        if (now.difference(ts).abs() > _maxSkew) throw const _Refused(401, 'Clock too far off, or a replay');
        if (_seen.containsKey(nonce)) throw const _Refused(401, 'Replayed message');
        _seen[nonce] = now;
        inner = BleMessage(id, {...message.header, 'sealedBy': sealedBy}, message.body);
        _peerOf[peer] = sealedBy;
      } else {
        // Only the dispatcher may say who sealed a message.
        inner = BleMessage(id, {...request.header}..remove('sealedBy'), request.body);
      }
      response = await handler(inner);
    } on _Refused catch (e) {
      response = BleResponse(e.status, const {}, Uint8List.fromList(utf8.encode(jsonEncode({'error': e.message}))));
    } catch (e) {
      response = BleResponse(500, const {}, Uint8List.fromList(utf8.encode(jsonEncode({'error': '$e'}))));
    }
    var message = encodeMessage({'status': response.status, 'headers': response.headers, 'rn': ?nonce}, response.body);
    if (key != null) {
      message = encodeMessage({'sealed': true}, sealBytes(key, message, aad: _aad('res', id)));
    }
    for (final c in chunkMessage(id, message, maxChunk)) {
      await sendChunk(c);
    }
  }

  void forget(String peer) {
    _peers.remove(peer);
    _peerOf.remove(peer);
  }
}

class _Pending {
  _Pending(this.completer, this.seal, this.nonce);
  final Completer<BleResponse> completer;
  final BleSeal? seal;
  final String? nonce;
}

class _Refused implements Exception {
  const _Refused(this.status, this.message);
  final int status;
  final String message;
}

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Screen Mirroring: a phone's screen (iPhone or Android) on a paired Mac or
/// PC, lossless and fast.
///
/// The phone captures its screen natively (an Android virtual display; on
/// the iPhone a ReplayKit broadcast extension, see platform/screen_source.dart)
/// and splits it into tiles; only the tiles that changed since the last
/// frame are sent, as exact pixels (lossless: text stays pin sharp),
/// deflated with zlib in a worker isolate. The viewer keeps the whole
/// picture and paints changed tiles into it.
///
/// A packet, as native capture hands it over (little-endian):
///
/// ```
///  0  'S' 'K' 'M' '1'
///  4  u16 width, u16 height         the whole picture, in pixels
///  8  i16 cursorX, i16 cursorY       -1, -1: no pointer on this screen
/// 12  u16 tileCount, u16 flags        bit 0: every tile (a key frame)
///                                     bit 1: RGBA (Android) instead of BGRA
///                                     bits 2-3: quarter turns clockwise to
///                                     show it upright (iPhone, sideways)
/// 16  tiles: u16 x, u16 y, u16 w, u16 h, then w*h*4 bytes, row by row
/// ```
///
/// On the wire each packet is zlib-compressed, one binary WebSocket message.
/// Text messages are JSON: from the phone `{t: status|started|error, msg}`,
/// from the viewer `{t: ack}` after each binary message (so the phone never
/// gets more than two frames ahead), `{t: keyframe}` and `{t: sharp, on}`.
class MirrorPacket {
  MirrorPacket({
    required this.width,
    required this.height,
    required this.cursorX,
    required this.cursorY,
    required this.tiles,
    this.keyframe = false,
    this.rgba = false,
    this.turns = 0,
  });

  static const headerSize = 16;
  static const tileHeaderSize = 8;
  static const _magic = [0x53, 0x4B, 0x4D, 0x31]; // SKM1

  final int width, height, cursorX, cursorY;
  final List<MirrorTile> tiles;
  final bool keyframe;

  /// Pixels are RGBA (Android's order) rather than BGRA.
  final bool rgba;

  /// Quarter turns clockwise that show the picture upright.
  final int turns;

  bool get hasCursor => cursorX >= 0 && cursorY >= 0;

  /// Reads a packet; throws [FormatException] if it's damaged.
  static MirrorPacket parse(Uint8List bytes) {
    if (bytes.length < headerSize) throw const FormatException('Mirror packet too short');
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) throw const FormatException('Not a mirror packet');
    }
    final d = ByteData.sublistView(bytes);
    final width = d.getUint16(4, Endian.little);
    final height = d.getUint16(6, Endian.little);
    final cursorX = d.getInt16(8, Endian.little);
    final cursorY = d.getInt16(10, Endian.little);
    final count = d.getUint16(12, Endian.little);
    final flags = d.getUint16(14, Endian.little);
    final tiles = <MirrorTile>[];
    var o = headerSize;
    for (var i = 0; i < count; i++) {
      if (o + tileHeaderSize > bytes.length) throw const FormatException('Mirror packet cut short');
      final x = d.getUint16(o, Endian.little);
      final y = d.getUint16(o + 2, Endian.little);
      final w = d.getUint16(o + 4, Endian.little);
      final h = d.getUint16(o + 6, Endian.little);
      o += tileHeaderSize;
      final size = w * h * 4;
      if (o + size > bytes.length || x + w > width || y + h > height) {
        throw const FormatException('Mirror tile out of range');
      }
      tiles.add(MirrorTile(x, y, w, h, Uint8List.sublistView(bytes, o, o + size)));
      o += size;
    }
    return MirrorPacket(
      width: width,
      height: height,
      cursorX: cursorX,
      cursorY: cursorY,
      tiles: tiles,
      keyframe: flags & 1 != 0,
      rgba: flags & 2 != 0,
      turns: (flags >> 2) & 3,
    );
  }

  /// The number of tiles in a packet, without reading it all.
  static int tileCountOf(Uint8List bytes) =>
      bytes.length < headerSize ? 0 : ByteData.sublistView(bytes).getUint16(12, Endian.little);

  /// The pointer position in a packet, as one number (to notice moves).
  static int cursorOf(Uint8List bytes) =>
      bytes.length < headerSize ? -1 : ByteData.sublistView(bytes).getUint32(8, Endian.little);

  /// Builds a packet (the native side does this too; used in tests and by
  /// [MirrorCanvas.keyframePacket]).
  Uint8List toBytes() {
    var size = headerSize;
    for (final t in tiles) {
      size += tileHeaderSize + t.pixels.length;
    }
    final out = Uint8List(size);
    final d = ByteData.sublistView(out);
    out.setRange(0, 4, _magic);
    d.setUint16(4, width, Endian.little);
    d.setUint16(6, height, Endian.little);
    d.setInt16(8, cursorX, Endian.little);
    d.setInt16(10, cursorY, Endian.little);
    d.setUint16(12, tiles.length, Endian.little);
    d.setUint16(14, (keyframe ? 1 : 0) | (rgba ? 2 : 0) | (turns & 3) << 2, Endian.little);
    var o = headerSize;
    for (final t in tiles) {
      d.setUint16(o, t.x, Endian.little);
      d.setUint16(o + 2, t.y, Endian.little);
      d.setUint16(o + 4, t.w, Endian.little);
      d.setUint16(o + 6, t.h, Endian.little);
      o += tileHeaderSize;
      out.setRange(o, o + t.pixels.length, t.pixels);
      o += t.pixels.length;
    }
    return out;
  }
}

class MirrorTile {
  MirrorTile(this.x, this.y, this.w, this.h, this.pixels);
  final int x, y, w, h;

  /// BGRA (or RGBA, see [MirrorPacket.rgba]), [w] * 4 bytes per row, [h] rows.
  final Uint8List pixels;
}

/// The viewer's copy of the whole screen, updated tile by tile.
class MirrorCanvas {
  int width = 0, height = 0;
  Uint8List pixels = Uint8List(0);
  int cursorX = -1, cursorY = -1;

  /// [pixels] are RGBA rather than BGRA.
  bool rgba = false;

  /// Quarter turns clockwise to show it upright.
  int turns = 0;

  bool get isEmpty => width == 0 || height == 0;

  /// Paints [packet] in. A new size (or pixel order) starts a new, black
  /// picture.
  void apply(MirrorPacket packet) {
    if (packet.width != width || packet.height != height || packet.rgba != rgba) {
      width = packet.width;
      height = packet.height;
      rgba = packet.rgba;
      pixels = Uint8List(width * height * 4);
    }
    turns = packet.turns;
    cursorX = packet.cursorX;
    cursorY = packet.cursorY;
    final stride = width * 4;
    for (final t in packet.tiles) {
      final row = t.w * 4;
      for (var y = 0; y < t.h; y++) {
        final to = (t.y + y) * stride + t.x * 4;
        pixels.setRange(to, to + row, t.pixels, y * row);
      }
    }
  }
}

/// Deflates and inflates in a worker isolate, so a big frame never stalls
/// the app's UI. Bytes cross over without copying (TransferableTypedData).
class MirrorZip {
  MirrorZip._(this._send, this._replies, this._isolate);

  final SendPort _send;
  final ReceivePort _replies;
  final Isolate _isolate;
  final _waiting = <int, Completer<Uint8List>>{};
  var _next = 0;

  static Future<MirrorZip> start() async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    late MirrorZip zip;
    replies.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is List && message.length == 2) {
        final c = zip._waiting.remove(message[0] as int);
        final payload = message[1];
        if (payload is TransferableTypedData) {
          c?.complete(payload.materialize().asUint8List());
        } else {
          c?.completeError(FormatException('$payload'));
        }
      }
    });
    final isolate = await Isolate.spawn(_worker, replies.sendPort, debugName: 'sidekick-mirror-zip');
    zip = MirrorZip._(await ready.future, replies, isolate);
    return zip;
  }

  /// zlib, fast (level 1): screens compress well even so.
  Future<Uint8List> compress(Uint8List bytes) => _run(true, bytes);

  Future<Uint8List> decompress(Uint8List bytes) => _run(false, bytes);

  Future<Uint8List> _run(bool compress, Uint8List bytes) {
    final id = _next++;
    final c = Completer<Uint8List>();
    _waiting[id] = c;
    _send.send([
      id,
      compress,
      TransferableTypedData.fromList([bytes]),
    ]);
    return c.future;
  }

  void close() {
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
    for (final c in _waiting.values) {
      c.completeError(StateError('closed'));
    }
    _waiting.clear();
  }

  static void _worker(SendPort replies) {
    final requests = ReceivePort();
    replies.send(requests.sendPort);
    final deflate = ZLibCodec(level: 1);
    requests.listen((message) {
      final m = message as List;
      final id = m[0] as int;
      try {
        final input = (m[2] as TransferableTypedData).materialize().asUint8List();
        final output = m[1] == true ? deflate.encode(input) : deflate.decode(input);
        replies.send([
          id,
          TransferableTypedData.fromList([output is Uint8List ? output : Uint8List.fromList(output)]),
        ]);
      } catch (e) {
        replies.send([id, '$e']);
      }
    });
  }
}

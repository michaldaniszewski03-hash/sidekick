import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Why this screen can't be mirrored right now, in words for the viewer.
class MirrorException implements Exception {
  MirrorException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// This phone's screen, for Screen Mirroring (see core/mirror.dart).
///
/// The native side captures continuously while started, and keeps track of
/// which tiles changed; each [frame] call takes the changes since the last
/// one as a packet.
abstract class ScreenSource {
  bool get supported;

  /// What the person holding this phone does to start, for the viewer.
  String get startHint;

  /// Starts capturing, for [viewer] (named in the phone's notification).
  /// [sharp]: every pixel; otherwise half the size each way, much faster
  /// and still lossless. Throws [MirrorException].
  Future<void> start({required bool sharp, required String viewer});

  /// What changed since the last call, as a packet; null once capture has
  /// stopped.
  Future<Uint8List?> frame();

  /// Sends every tile next time (a viewer that lost track).
  Future<void> keyframe();

  /// Switches between every pixel and half size, without asking again.
  Future<void> setSharp(bool sharp);

  Future<void> stop();

  static ScreenSource forCurrentPlatform() => Platform.isAndroid
      ? AndroidScreen()
      : Platform.isIOS
      ? IphoneScreen()
      : _NoScreenSource();
}

class _NoScreenSource implements ScreenSource {
  @override
  bool get supported => false;
  @override
  String get startHint => '';
  @override
  Future<void> start({required bool sharp, required String viewer}) async =>
      throw MirrorException('Only iPhones and Android phones can be mirrored.');
  @override
  Future<Uint8List?> frame() async => null;
  @override
  Future<void> keyframe() async {}
  @override
  Future<void> setSharp(bool sharp) async {}
  @override
  Future<void> stop() async {}
}

/// Android: MediaProjection into a virtual display (ScreenMirror.kt), on the
/// engine's `sidekick/mirror` channel, so it runs without the screen too.
class AndroidScreen implements ScreenSource {
  static const _channel = MethodChannel('sidekick/mirror');

  @override
  bool get supported => true;

  @override
  String get startHint => 'Tap Start now on the phone';

  @override
  Future<void> start({required bool sharp, required String viewer}) async {
    try {
      // Waits for the person to answer Android's own question.
      await _channel
          .invokeMethod<void>('start', {'sharp': sharp, 'viewer': viewer})
          .timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw MirrorException('Screen sharing wasn\'t started on the phone.');
    } on PlatformException catch (e) {
      throw MirrorException(e.message ?? "Couldn't capture the phone's screen.");
    } on MissingPluginException {
      throw MirrorException('Update Sidekick on the phone.');
    }
  }

  @override
  Future<Uint8List?> frame() async {
    try {
      final packet = await _channel.invokeMethod<Uint8List>('frame').timeout(const Duration(seconds: 5));
      return packet == null || packet.isEmpty ? null : packet;
    } on TimeoutException {
      throw MirrorException('Screen sharing stopped on the phone.');
    } on PlatformException catch (e) {
      throw MirrorException(e.message ?? 'Screen sharing stopped on the phone.');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> keyframe() => _quietly('keyframe');

  @override
  Future<void> setSharp(bool sharp) => _quietly('sharp', {'on': sharp});

  @override
  Future<void> stop() => _quietly('stop');

  Future<void> _quietly(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {}
  }
}

/// iPhone: ReplayKit's broadcast extension (ios/SidekickMirror) captures the
/// screen, even while other apps are open, and hands the changes to this
/// app over a loopback connection on [port], one packet per request:
///
/// - the extension says `SKB1` when it connects;
/// - this side sends one byte: `N` (the next packet), `K` (a key frame),
///   `S` / `F` (sharp / fast) or `Q` (stop);
/// - the extension answers `N` with a u32 length (little-endian) and the
///   packet.
///
/// iOS only starts a broadcast when the person taps Start Broadcast: the
/// app opens that sheet (`startBroadcast` on `sidekick/ios`), and Control
/// Center's Screen Recording → Sidekick works too.
class IphoneScreen implements ScreenSource {
  IphoneScreen({this.port = defaultPort, this.openPicker = _openPicker});

  static const defaultPort = 53319;
  static const _ios = MethodChannel('sidekick/ios');

  final int port;
  final Future<void> Function() openPicker;
  ServerSocket? _server;
  BroadcastLink? _link;

  static Future<void> _openPicker() async {
    try {
      await _ios.invokeMethod<void>('startBroadcast');
    } catch (_) {}
  }

  @override
  bool get supported => true;

  @override
  String get startHint => 'Tap Start Broadcast on the iPhone';

  @override
  Future<void> start({required bool sharp, required String viewer}) async {
    await stop();
    final ServerSocket server;
    try {
      // Loopback only: nothing off this iPhone can reach it.
      server = _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      throw MirrorException("Couldn't start Screen Mirroring on the iPhone. Try again.");
    }
    final connected = Completer<Socket>();
    server.listen((socket) {
      // One broadcast at a time; a second is turned away.
      if (connected.isCompleted) {
        socket.destroy();
      } else {
        connected.complete(socket);
      }
    });
    await openPicker();
    final Socket socket;
    try {
      socket = await connected.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      await stop();
      throw MirrorException("Screen broadcast wasn't started on the iPhone.");
    }
    final link = _link = BroadcastLink(socket);
    try {
      await link.hello();
    } catch (_) {
      await stop();
      throw MirrorException("The iPhone's screen broadcast didn't start.");
    }
    link.command(sharp ? 'S' : 'F');
  }

  @override
  Future<Uint8List?> frame() async {
    final link = _link;
    if (link == null) return null;
    try {
      return await link.next().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      throw MirrorException('The iPhone stopped sending its screen.');
    }
  }

  @override
  Future<void> keyframe() async => _link?.command('K');

  @override
  Future<void> setSharp(bool sharp) async => _link?.command(sharp ? 'S' : 'F');

  @override
  Future<void> stop() async {
    final link = _link, server = _server;
    _link = null;
    _server = null;
    if (link != null) {
      link.command('Q');
      await link.close();
    }
    await server?.close();
  }
}

/// The loopback connection to the iPhone's broadcast extension (see
/// [IphoneScreen]).
class BroadcastLink {
  BroadcastLink(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _sub = _socket.listen(
      (data) {
        _chunks.add(data);
        _available += data.length;
        _wake();
      },
      onDone: _end,
      onError: (Object _) => _end(),
      cancelOnError: true,
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final _chunks = <Uint8List>[];
  var _offset = 0;
  var _available = 0;
  var _closed = false;
  Completer<void>? _more;

  static const _hello = [0x53, 0x4B, 0x42, 0x31]; // SKB1

  void _wake() {
    _more?.complete();
    _more = null;
  }

  void _end() {
    _closed = true;
    _wake();
  }

  /// The extension's greeting; throws if it's something else.
  Future<void> hello() async {
    final bytes = await _read(4);
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _hello[i]) throw const FormatException('Not a Sidekick broadcast');
    }
  }

  void command(String c) {
    if (_closed) return;
    try {
      _socket.add([c.codeUnitAt(0)]);
    } catch (_) {}
  }

  /// Asks for the next packet; null once the broadcast has ended.
  Future<Uint8List?> next() async {
    if (_closed) return null;
    command('N');
    try {
      final size = ByteData.sublistView(await _read(4)).getUint32(0, Endian.little);
      if (size == 0) return null;
      return await _read(size);
    } on StateError {
      return null;
    }
  }

  Future<Uint8List> _read(int n) async {
    while (_available < n) {
      if (_closed) throw StateError('Broadcast ended');
      final c = _more = Completer<void>();
      await c.future;
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final chunk = _chunks.first;
      final take = (chunk.length - _offset).clamp(0, n - filled);
      out.setRange(filled, filled + take, chunk, _offset);
      filled += take;
      _offset += take;
      if (_offset == chunk.length) {
        _chunks.removeAt(0);
        _offset = 0;
      }
    }
    _available -= n;
    return out;
  }

  Future<void> close() async {
    _end();
    await _sub.cancel();
    try {
      await _socket.flush();
    } catch (_) {}
    _socket.destroy();
  }
}

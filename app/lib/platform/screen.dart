import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Why the screen can't be shared right now, in words for the viewer.
class ScreenCaptureException implements Exception {
  ScreenCaptureException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Captures *this* device's main screen as JPEG frames, for a paired device
/// that wants to see it (see `/v1/screen`).
abstract class ScreenCapturer {
  bool get supported;

  /// Gets ready: asks for permission (Mac) or the user's consent (Android).
  /// [onStatus] tells the viewer what we're waiting for.
  Future<void> start({required int maxWidth, void Function(String message)? onStatus});

  /// The latest frame, at most [maxWidth] pixels wide, JPEG [quality]
  /// 0–100. Null when there's nothing new yet.
  Future<Uint8List?> frame({required int maxWidth, required int quality});

  Future<void> stop();

  static ScreenCapturer forCurrentPlatform() {
    if (Platform.isWindows) return _ChannelCapturer(const MethodChannel('sidekick/screen'), needsStart: false);
    if (Platform.isMacOS) return _ChannelCapturer(const MethodChannel('sidekick/macos'));
    if (Platform.isAndroid) return _ChannelCapturer(const MethodChannel('sidekick/android'));
    return UnsupportedScreenCapturer();
  }
}

class UnsupportedScreenCapturer implements ScreenCapturer {
  @override
  bool get supported => false;
  @override
  Future<void> start({required int maxWidth, void Function(String message)? onStatus}) async =>
      throw ScreenCaptureException("This device can't share its screen.");
  @override
  Future<Uint8List?> frame({required int maxWidth, required int quality}) async => null;
  @override
  Future<void> stop() async {}
}

/// The native side answers `screenStart`, `screenFrame` and `screenStop`
/// (Windows only needs `screenFrame`). Errors come back as
/// PlatformExceptions whose message is meant for the viewer.
class _ChannelCapturer implements ScreenCapturer {
  _ChannelCapturer(this._channel, {this.needsStart = true});

  final MethodChannel _channel;
  final bool needsStart;

  @override
  bool get supported => true;

  @override
  Future<void> start({required int maxWidth, void Function(String message)? onStatus}) async {
    if (!needsStart) return;
    if (Platform.isAndroid) onStatus?.call('Waiting for someone to allow screen sharing on the phone…');
    try {
      await _channel
          .invokeMethod<void>('screenStart', {'maxWidth': maxWidth})
          // Someone has to tap "Start now" on a phone; don't wait forever.
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw ScreenCaptureException(
        'Nobody allowed screen sharing in time. Open Sidekick on the device, then try again.',
      );
    } on PlatformException catch (e) {
      throw ScreenCaptureException(e.message ?? "Couldn't start sharing the screen.");
    } on MissingPluginException {
      throw ScreenCaptureException("This device can't share its screen.");
    }
  }

  @override
  Future<Uint8List?> frame({required int maxWidth, required int quality}) async {
    try {
      return await _channel.invokeMethod<Uint8List>('screenFrame', {'maxWidth': maxWidth, 'quality': quality});
    } on PlatformException catch (e) {
      throw ScreenCaptureException(e.message ?? 'Screen sharing stopped.');
    } on MissingPluginException {
      throw ScreenCaptureException("This device can't share its screen.");
    }
  }

  @override
  Future<void> stop() async {
    if (!needsStart) return;
    try {
      await _channel.invokeMethod<void>('screenStop');
    } catch (_) {}
  }
}

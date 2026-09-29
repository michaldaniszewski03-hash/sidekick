import 'package:flutter/services.dart';

import '../core/models.dart';
import 'media.dart';

/// Media control of *this* iPhone for a paired computer, via
/// ios/Runner/AppDelegate.swift. iOS only allows the system volume and Apple
/// Music; the status carries a note explaining that.
class IosMediaController implements MediaController {
  static const _channel = MethodChannel('sidekick/ios');

  @override
  bool get supported => true;

  @override
  Future<MediaStatus> status() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('mediaStatus');
      return MediaStatus.fromJson(map ?? const {});
    } on PlatformException {
      return const MediaStatus();
    } on MissingPluginException {
      return const MediaStatus();
    }
  }

  @override
  Future<void> perform(MediaAction action, {Duration? position, double? volume}) => _channel.invokeMethod(
    'mediaAction',
    {'action': action.name, 'positionMs': position?.inMilliseconds, 'volume': volume},
  );

  @override
  Future<void> dispose() async {}
}

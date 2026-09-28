import 'package:flutter/services.dart';

import '../core/models.dart';
import 'input.dart';
import 'media.dart';

/// Which special Android permissions the user has granted Sidekick.
class AndroidPermissions {
  const AndroidPermissions({this.accessibility = false, this.notifications = false, this.allFiles = false});

  /// The accessibility service is on: paired devices can control the phone.
  final bool accessibility;

  /// Notification access: we can see and control other apps' media.
  final bool notifications;

  /// "All files access": paired devices can browse the phone's storage.
  final bool allFiles;
}

/// Calls into the Kotlin side (MainActivity.kt).
abstract final class AndroidBridge {
  static const _channel = MethodChannel('sidekick/android');

  /// Last known permissions; refreshed on start and whenever the app resumes.
  static AndroidPermissions permissions = const AndroidPermissions();

  static Future<AndroidPermissions> refresh() async {
    final map = await _channel.invokeMapMethod<String, bool>('permissions') ?? const {};
    return permissions = AndroidPermissions(
      accessibility: map['accessibility'] ?? false,
      notifications: map['notifications'] ?? false,
      allFiles: map['allFiles'] ?? false,
    );
  }

  static Future<void> acquireMulticastLock() => _channel.invokeMethod('acquireMulticastLock');
  static Future<String?> storageRoot() => _channel.invokeMethod<String>('storageRoot');
  static Future<void> openAccessibilitySettings() => _channel.invokeMethod('openAccessibilitySettings');
  static Future<void> openNotificationAccessSettings() => _channel.invokeMethod('openNotificationAccessSettings');
  static Future<void> openAppSettings() => _channel.invokeMethod('openAppSettings');
  static Future<void> requestAllFilesAccess() => _channel.invokeMethod('requestAllFilesAccess');

  static void input(Map<String, Object?> msg) => _channel.invokeMethod('input', msg).catchError((_) => null);

  static Future<Map<String, dynamic>> mediaStatus() async =>
      Map<String, dynamic>.from(await _channel.invokeMapMethod<String, dynamic>('mediaStatus') ?? const {});

  static Future<void> mediaAction(String action, {int? positionMs, double? volume}) =>
      _channel.invokeMethod('mediaAction', {'action': action, 'positionMs': positionMs, 'volume': volume});
}

/// Remote input handled by SidekickAccessibilityService.kt. It speaks the
/// same message format as the network protocol.
class AndroidInputInjector implements InputInjector {
  @override
  bool get supported => AndroidBridge.permissions.accessibility;

  static String _button(MouseButton b) => b.name;

  @override
  void moveBy(int dx, int dy) => AndroidBridge.input({'t': 'move', 'dx': dx, 'dy': dy});
  @override
  void button(MouseButton button, {required bool down}) =>
      AndroidBridge.input({'t': down ? 'down' : 'up', 'b': _button(button)});
  @override
  void click(MouseButton button, {int count = 1}) =>
      AndroidBridge.input({'t': 'click', 'b': _button(button), 'n': count});
  @override
  void scroll({int dx = 0, int dy = 0}) => AndroidBridge.input({'t': 'scroll', 'dx': dx, 'dy': dy});
  @override
  void key(String key, {List<String> modifiers = const []}) =>
      AndroidBridge.input({'t': 'key', 'k': key, 'mods': modifiers});
  @override
  void text(String text) => AndroidBridge.input({'t': 'text', 's': text});
  @override
  void virtualKey(int vk) {}
}

class AndroidMediaController implements MediaController {
  /// Volume works without permissions; now-playing info needs notification
  /// access (the status just reports "nothing playing" without it).
  @override
  bool get supported => true;

  @override
  Future<MediaStatus> status() async {
    try {
      return MediaStatus.fromJson(await AndroidBridge.mediaStatus());
    } on PlatformException {
      return const MediaStatus();
    }
  }

  @override
  Future<void> perform(MediaAction action, {Duration? position, double? volume}) =>
      AndroidBridge.mediaAction(action.name, positionMs: position?.inMilliseconds, volume: volume);

  @override
  Future<void> dispose() async {}
}

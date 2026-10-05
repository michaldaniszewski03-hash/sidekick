import 'package:flutter/services.dart';

import 'input.dart';

/// Which special Android permissions the user has granted Sidekick.
class AndroidPermissions {
  const AndroidPermissions({this.accessibility = false, this.allFiles = false});

  /// The accessibility service is on: paired devices can control the phone.
  final bool accessibility;

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
      allFiles: map['allFiles'] ?? false,
    );
  }

  static Future<void> acquireMulticastLock() => _channel.invokeMethod('acquireMulticastLock');
  static Future<String?> storageRoot() => _channel.invokeMethod<String>('storageRoot');
  static Future<void> openAccessibilitySettings() => _channel.invokeMethod('openAccessibilitySettings');
  static Future<void> openAppSettings() => _channel.invokeMethod('openAppSettings');
  static Future<void> requestAllFilesAccess() => _channel.invokeMethod('requestAllFilesAccess');

  static void input(Map<String, Object?> msg) => _channel.invokeMethod('input', msg).catchError((_) => null);
}

/// What doesn't need Sidekick's screen (KeepRunning.kt): it works while
/// Sidekick runs in the background, even after it's swiped away.
abstract final class AndroidBackground {
  static const _channel = MethodChannel('sidekick/background');

  /// Keeps Sidekick running in the background (SidekickService), or not.
  static Future<void> keepRunning(bool on) async {
    try {
      await _channel.invokeMethod<void>('keepRunning', {'on': on});
    } catch (_) {}
  }

  /// Puts [text] in the clipboard, with or without the screen.
  static Future<bool> setClipboard(String text) async {
    try {
      await _channel.invokeMethod<void>('setClipboard', {'text': text});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Android isn't "optimising" Sidekick's battery (which stops it in the
  /// background on many phones).
  static Future<bool> batteryUnrestricted() async {
    try {
      return await _channel.invokeMethod<bool>('batteryUnrestricted') ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestBatteryUnrestricted() async {
    try {
      await _channel.invokeMethod<void>('requestBatteryUnrestricted');
    } catch (_) {}
  }
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
}

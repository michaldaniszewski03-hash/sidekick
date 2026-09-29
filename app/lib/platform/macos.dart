import 'package:flutter/services.dart';

import 'input.dart';

/// Calls into the Swift side (macos/Runner/MainFlutterWindow.swift).
abstract final class MacBridge {
  static const _channel = MethodChannel('sidekick/macos');

  /// Whether Sidekick may post input events (System Settings → Privacy &
  /// Security → Accessibility). Refreshed on start and when the app resumes.
  static bool accessibility = false;

  static Future<void> refresh() async {
    final map = await _channel.invokeMapMethod<String, bool>('permissions') ?? const {};
    accessibility = map['accessibility'] ?? false;
  }

  /// Shows the system prompt and opens the Accessibility settings pane.
  static Future<void> requestAccessibility() => _channel.invokeMethod('requestAccessibility');

  static void input(Map<String, Object?> msg) => _channel.invokeMethod('input', msg).catchError((_) => null);
}

/// Remote input via CGEvent. Same message format as the network protocol.
class MacInputInjector implements InputInjector {
  @override
  bool get supported => MacBridge.accessibility;

  @override
  void moveBy(int dx, int dy) => MacBridge.input({'t': 'move', 'dx': dx, 'dy': dy});
  @override
  void button(MouseButton button, {required bool down}) =>
      MacBridge.input({'t': down ? 'down' : 'up', 'b': button.name});
  @override
  void click(MouseButton button, {int count = 1}) => MacBridge.input({'t': 'click', 'b': button.name, 'n': count});
  @override
  void scroll({int dx = 0, int dy = 0}) => MacBridge.input({'t': 'scroll', 'dx': dx, 'dy': dy});
  @override
  void key(String key, {List<String> modifiers = const []}) =>
      MacBridge.input({'t': 'key', 'k': key, 'mods': modifiers});
  @override
  void text(String text) => MacBridge.input({'t': 'text', 's': text});
}

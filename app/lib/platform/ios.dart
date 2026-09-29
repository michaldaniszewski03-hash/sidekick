import 'package:flutter/services.dart';

const _channel = MethodChannel('sidekick/ios');

/// Keeps Sidekick running while other apps are open (silent, mixed audio),
/// so a paired computer can still reach the iPhone.
Future<void> setIosKeepAlive(bool on) async {
  try {
    await _channel.invokeMethod('setKeepAlive', {'on': on});
  } catch (_) {}
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Apple's peer-to-peer Wi-Fi (the link AirDrop uses) between iPhones and
/// Macs, with no router or shared network: SidekickP2P.swift. Each device
/// advertises itself; [connect] gives a port on 127.0.0.1 that leads to
/// another one, and Sidekick's usual HTTPS (certificate pinned) goes
/// through it unchanged.
class AppleP2P {
  AppleP2P._(this._channel) {
    _channel?.setMethodCallHandler((call) async {
      if (call.method == 'peers') peers.value = {...(call.arguments as List).cast<String>()};
      return null;
    });
  }

  factory AppleP2P.forCurrentPlatform() =>
      AppleP2P._(Platform.isIOS || Platform.isMacOS ? const MethodChannel('sidekick/p2p') : null);

  /// Nothing to offer (Windows and Android, and tests).
  factory AppleP2P.none() => AppleP2P._(null);

  final MethodChannel? _channel;

  bool get supported => _channel != null;

  /// Device ids in reach over the link, while [browse] is on.
  final peers = ValueNotifier<Set<String>>(const {});

  bool _browsing = false;

  /// Advertises this device, whose server is on [port]. Safe to repeat.
  Future<void> start({required String id, required int port}) => _call('start', {'id': id, 'port': port});

  /// Looks for other devices. It takes some of the Wi-Fi radio's time, so
  /// only while it's needed.
  Future<void> browse(bool on) async {
    if (!supported || on == _browsing) return;
    _browsing = on;
    if (!on) peers.value = const {};
    await _call('browse', {'on': on});
  }

  bool get browsing => _browsing;

  /// A port on 127.0.0.1 that leads to device [id], or null if it's not in
  /// reach.
  Future<int?> connect(String id) async {
    if (!supported || !peers.value.contains(id)) return null;
    try {
      return await _channel!.invokeMethod<int>('connect', {'id': id});
    } on PlatformException catch (e) {
      debugPrint('Sidekick: direct link to $id: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> stop() async {
    _browsing = false;
    peers.value = const {};
    await _call('stop');
  }

  Future<void> _call(String method, [Object? arguments]) async {
    if (!supported) return;
    try {
      await _channel!.invokeMethod<void>(method, arguments);
    } on PlatformException catch (e) {
      debugPrint('Sidekick: direct link $method: $e');
    } on MissingPluginException {
      // An older native build.
    }
  }
}

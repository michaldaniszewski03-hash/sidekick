import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// A friendly name for this device, used until the user picks their own in
/// Settings:
/// * Windows: the PC's name (e.g. "ambiaPC")
/// * Mac: the computer name (e.g. "Michał's MacBook Pro")
/// * iPhone/iPad: the model (e.g. "iPhone 12"). iOS 16+ only tells apps
///   "iPhone" instead of the name the owner gave it.
/// * Android: the device name from Settings (e.g. "Galaxy S23"), else the
///   maker and model (e.g. "Google Pixel 8")
/// and "Unknown iPhone" / "Unknown Android" when even that isn't known.
Future<String> detectDeviceName() async {
  final info = DeviceInfoPlugin();
  try {
    if (Platform.isWindows) {
      return _clean(_host()) ?? _clean((await info.windowsInfo).computerName) ?? 'Windows PC';
    }
    if (Platform.isMacOS) {
      final mac = await info.macOsInfo;
      return _clean(mac.computerName) ?? _clean(_host()) ?? _clean(mac.modelName) ?? 'Mac';
    }
    if (Platform.isIOS) {
      final ios = await info.iosInfo;
      final kind = ios.model.toLowerCase().contains('ipad') ? 'iPad' : 'iPhone';
      return iosName(name: ios.name, modelName: ios.modelName, kind: kind);
    }
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      return androidName(name: android.name, manufacturer: android.manufacturer, model: android.model);
    }
    if (Platform.isLinux) {
      return _clean(_host()) ?? _clean((await info.linuxInfo).prettyName) ?? 'Linux PC';
    }
  } catch (_) {
    // Fall through to the generic names below.
  }
  if (Platform.isIOS) return 'Unknown iPhone';
  if (Platform.isAndroid) return 'Unknown Android';
  return _clean(_host()) ?? 'My computer';
}

/// iOS: the owner's name for the device if iOS shares it, else the model.
String iosName({required String name, required String modelName, String kind = 'iPhone'}) {
  final given = _clean(name);
  const generic = {'iphone', 'ipad', 'ipod touch'};
  if (given != null && !generic.contains(given.toLowerCase())) return given;
  final model = _clean(modelName);
  if (model != null && model != 'Unknown device') return model;
  return 'Unknown $kind';
}

/// Android: the name from Settings, else maker + model, else "Unknown Android".
String androidName({required String name, required String manufacturer, required String model}) {
  final given = _clean(name);
  if (given != null) return given;
  final m = _clean(model);
  if (m == null) return 'Unknown Android';
  final maker = _clean(manufacturer);
  if (maker == null || m.toLowerCase().startsWith(maker.toLowerCase())) return m;
  return '${maker[0].toUpperCase()}${maker.substring(1)} $m';
}

/// Names Sidekick used to make up before it could read real ones.
bool isLegacyDefaultName(String name) =>
    RegExp(r'^My (ios|android|macos|windows|linux|unknown)$').hasMatch(name) || name == 'localhost';

String _host() => Platform.localHostname.split('.').first;

String? _clean(String? s) {
  final t = s?.trim();
  if (t == null || t.isEmpty || t == 'localhost' || t.toLowerCase() == 'unknown') return null;
  return t.length > 40 ? t.substring(0, 40) : t;
}

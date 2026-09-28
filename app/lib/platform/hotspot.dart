import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A private Wi-Fi network one device opens for another, AirDrop style:
/// Bluetooth carries the name and password, then files and remote control
/// run over Wi-Fi at full speed.
class HotspotCredentials {
  const HotspotCredentials({
    required this.ssid,
    required this.passphrase,
    this.security = 'wpa2',
    this.addresses = const [],
  });

  final String ssid;
  final String passphrase;

  /// `wpa2` (also covers WPA2/WPA3 transition mode) or `wpa3`.
  final String security;

  /// The host's IPv4 addresses on the hotspot.
  final List<String> addresses;

  Map<String, Object?> toJson() => {
    'ssid': ssid,
    'passphrase': passphrase,
    'security': security,
    'addresses': addresses,
  };

  factory HotspotCredentials.fromJson(Map<String, dynamic> json) => HotspotCredentials(
    ssid: json['ssid'] as String,
    passphrase: json['passphrase'] as String,
    security: (json['security'] as String?) ?? 'wpa2',
    addresses: [for (final a in (json['addresses'] as List?) ?? const []) '$a'],
  );
}

class DirectLinkException implements Exception {
  DirectLinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Opens or joins a direct Wi-Fi link. Phones open a hotspot (Android's
/// local-only hotspot needs no mobile data and no setup); computers join it.
abstract class DirectLink {
  /// Can open a hotspot for another device to join.
  bool get canHost => false;

  /// Can join another device's hotspot.
  bool get canJoin => false;

  Future<HotspotCredentials> host() => throw DirectLinkException("This device can't open a hotspot.");
  Future<void> stopHosting() async {}

  /// Joins [c] and returns our own addresses on it.
  Future<List<String>> join(HotspotCredentials c) => throw DirectLinkException("This device can't join a hotspot.");
  Future<void> leave() async {}

  static DirectLink forCurrentPlatform() {
    if (Platform.isAndroid) return AndroidDirectLink();
    if (Platform.isWindows) return WindowsDirectLink();
    if (Platform.isMacOS) return MacDirectLink();
    return NoDirectLink();
  }
}

class NoDirectLink extends DirectLink {}

/// IPv4 addresses of this device, excluding loopback.
Future<List<String>> _ipv4() async => [
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
    for (final a in i.addresses)
      if (!a.isLoopback && !a.isLinkLocal) a.address,
];

String _prefix24(String ip) => ip.substring(0, ip.lastIndexOf('.'));

/// Waits until this device has an address on the same /24 as one of
/// [hostAddresses] and returns our addresses there.
Future<List<String>> waitForSubnet(List<String> hostAddresses, {Duration timeout = const Duration(seconds: 25)}) async {
  final deadline = DateTime.now().add(timeout);
  final hosts = hostAddresses.map(_prefix24).toSet();
  while (DateTime.now().isBefore(deadline)) {
    final mine = [
      for (final a in await _ipv4())
        if (hosts.contains(_prefix24(a)) && !hostAddresses.contains(a)) a,
    ];
    if (mine.isNotEmpty) return mine;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw DirectLinkException("Joined the hotspot but didn't get an address on it.");
}

// ---------------------------------------------------------------- Android

class AndroidDirectLink extends DirectLink {
  static const _channel = MethodChannel('sidekick/android');
  HotspotCredentials? _current;
  Timer? _safety;

  @override
  bool get canHost => true;

  @override
  Future<HotspotCredentials> host() async {
    final current = _current;
    if (current != null) return current;
    final before = (await _ipv4()).toSet();
    final Map<Object?, Object?> result;
    try {
      result = (await _channel.invokeMapMethod<Object?, Object?>('startHotspot'))!;
    } on PlatformException catch (e) {
      throw DirectLinkException(e.message ?? "Couldn't open a hotspot.");
    }
    // The hotspot's own address shows up a moment after it starts.
    var added = <String>[];
    for (var i = 0; i < 12 && added.isEmpty; i++) {
      added = (await _ipv4()).where((a) => !before.contains(a)).toList();
      if (added.isEmpty) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final ssid = result['ssid'];
    final passphrase = result['passphrase'];
    if (ssid is! String || passphrase is! String) {
      await stopHosting();
      throw DirectLinkException("The phone opened a hotspot but didn't share its password.");
    }
    final creds = HotspotCredentials(
      ssid: ssid,
      passphrase: passphrase,
      security: (result['security'] as String?) ?? 'wpa2',
      addresses: added.isNotEmpty
          ? added
          : [
              for (final a in await _ipv4())
                if (a.startsWith('192.168.')) a,
            ],
    );
    _current = creds;
    // Never leave a hotspot running forgotten.
    _safety?.cancel();
    _safety = Timer(const Duration(minutes: 30), stopHosting);
    return creds;
  }

  @override
  Future<void> stopHosting() async {
    _safety?.cancel();
    _current = null;
    try {
      await _channel.invokeMethod<void>('stopHotspot');
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- Windows

class WindowsDirectLink extends DirectLink {
  String? _joined;
  String? _previousProfile;

  @override
  bool get canJoin => true;

  static String _xml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<ProcessResult> _netsh(List<String> args) => Process.run('netsh', ['wlan', ...args]);

  @override
  Future<List<String>> join(HotspotCredentials c) async {
    // Remember the current network so we can go back to it afterwards.
    // "Profile" is "Profil" in some languages; the value is what matters.
    final show = await _netsh(['show', 'interfaces']);
    final match = RegExp(r'^\s*Profil\w*\s*:\s*(.+?)\s*$', multiLine: true).firstMatch('${show.stdout}');
    _previousProfile = match?.group(1);

    final auth = c.security == 'wpa3' ? 'WPA3SAE' : 'WPA2PSK';
    final profile =
        '''<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>${_xml(c.ssid)}</name>
  <SSIDConfig><SSID><name>${_xml(c.ssid)}</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM><security>
    <authEncryption><authentication>$auth</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>${_xml(c.passphrase)}</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>''';
    final dir = await Directory.systemTemp.createTemp('sidekick_wlan');
    try {
      final file = File(p.join(dir.path, 'profile.xml'));
      await file.writeAsString(profile);
      final add = await _netsh(['add', 'profile', 'filename=${file.path}', 'user=current']);
      if (add.exitCode != 0) throw DirectLinkException("Windows didn't accept the hotspot: ${add.stdout}".trim());
    } finally {
      await dir.delete(recursive: true);
    }
    _joined = c.ssid;
    final connect = await _netsh(['connect', 'name=${c.ssid}', 'ssid=${c.ssid}']);
    if (connect.exitCode != 0) {
      await leave();
      throw DirectLinkException("Couldn't join the phone's hotspot. Is Wi-Fi turned on?");
    }
    try {
      return await waitForSubnet(c.addresses);
    } catch (_) {
      await leave();
      rethrow;
    }
  }

  @override
  Future<void> leave() async {
    final ssid = _joined;
    _joined = null;
    if (ssid == null) return;
    await _netsh(['delete', 'profile', 'name=$ssid']);
    final previous = _previousProfile;
    if (previous != null && previous != ssid) await _netsh(['connect', 'name=$previous']);
  }
}

// ---------------------------------------------------------------- macOS

class MacDirectLink extends DirectLink {
  String? _joined;
  String? _device;

  @override
  bool get canJoin => true;

  /// The Wi-Fi interface, usually en0.
  Future<String> _wifiDevice() async {
    if (_device != null) return _device!;
    final ports = await Process.run('networksetup', ['-listallhardwareports']);
    final match = RegExp(r'Hardware Port: (?:Wi-Fi|AirPort)\s*\nDevice: (\S+)').firstMatch('${ports.stdout}');
    if (match == null) throw DirectLinkException('This Mac has no Wi-Fi.');
    return _device = match.group(1)!;
  }

  @override
  Future<List<String>> join(HotspotCredentials c) async {
    final device = await _wifiDevice();
    await Process.run('networksetup', ['-setairportpower', device, 'on']);
    final result = await Process.run('networksetup', ['-setairportnetwork', device, c.ssid, c.passphrase]);
    // networksetup exits 0 even when it fails, but then prints why.
    final output = '${result.stdout}${result.stderr}'.trim();
    if (result.exitCode != 0 || output.isNotEmpty) {
      throw DirectLinkException("Couldn't join the phone's hotspot${output.isEmpty ? '' : ': $output'}");
    }
    _joined = c.ssid;
    try {
      return await waitForSubnet(c.addresses);
    } catch (_) {
      await leave();
      rethrow;
    }
  }

  @override
  Future<void> leave() async {
    final ssid = _joined;
    _joined = null;
    if (ssid == null) return;
    // Forgetting it makes the Mac go back to its usual networks once the
    // phone closes the hotspot.
    await Process.run('networksetup', ['-removepreferredwirelessnetwork', await _wifiDevice(), ssid]);
  }
}

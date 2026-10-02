import 'package:flutter_test/flutter_test.dart';
import 'package:sidekick/core/discovery.dart';
import 'package:sidekick/core/models.dart';

void main() {
  test('only home and office networks count as Wi-Fi', () {
    expect(isPrivateLan('192.168.1.20'), isTrue);
    expect(isPrivateLan('10.0.0.7'), isTrue);
    expect(isPrivateLan('172.20.1.1'), isTrue);
    expect(isPrivateLan('172.32.1.1'), isFalse);
    expect(isPrivateLan('100.72.3.4'), isFalse, reason: 'carrier NAT / VPN range');
    expect(isPrivateLan('84.12.3.4'), isFalse);
  });

  test('mobile data, VPNs and virtual adapters are not Wi-Fi', () {
    for (final name in ['rmnet_data0', 'ccmni1', 'pdp_ip0', 'utun3', 'tun0', 'vEthernet (WSL)', 'docker0', 'vmnet8']) {
      expect(isCellularOrVpn(name), isTrue, reason: name);
    }
    for (final name in ['wlan0', 'en0', 'Wi-Fi', 'Ethernet', 'eth0']) {
      expect(isCellularOrVpn(name), isFalse, reason: name);
    }
  });

  test('devices say over Bluetooth whether they are on Wi-Fi', () {
    const info = DeviceInfo(id: 'a', name: 'Mac', platform: DevicePlatform.macos, port: 1, wifi: false);
    expect(DeviceInfo.fromJson(info.toJson()).wifi, isFalse);
    // Releases before 2.6.2 don't say.
    final old = info.toJson()..remove('wifi');
    expect(DeviceInfo.fromJson(old).wifi, isNull);
  });
}

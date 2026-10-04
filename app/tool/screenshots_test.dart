// Renders every tab to PNG so the UI can be checked without a Windows
// machine. Not part of the normal test run:
//
//   flutter test tool/screenshots_test.dart
//
// Screenshots land in build/screenshots/.

// This is a test in all but location.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidekick/app_state.dart';
import 'package:sidekick/core/client.dart';
import 'package:sidekick/core/crypto.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/core/trust.dart';
import 'package:sidekick/main.dart';
import 'package:sidekick/platform/files.dart';
import 'package:sidekick/platform/desktop_window.dart';
import 'package:sidekick/platform/input.dart';
import 'package:sidekick/ui/tray_panel.dart';
import 'package:sidekick/ui/widgets.dart';

Future<void> _loadFonts() async {
  final fonts = p.join(
    Platform.environment['FLUTTER_ROOT'] ?? '/home/user/tools/flutter',
    'bin/cache/artifacts/material_fonts',
  );
  Future<ByteData> read(String name) async => ByteData.sublistView(await File(p.join(fonts, name)).readAsBytes());
  await (FontLoader('Roboto')
        ..addFont(read('Roboto-Regular.ttf'))
        ..addFont(read('Roboto-Medium.ttf'))
        ..addFont(read('Roboto-Bold.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(read('MaterialIcons-Regular.otf'))).load();
}

void main() {
  testWidgets('screenshots', (tester) async {
    // Widget tests fake all HTTP by default; this one needs real sockets.
    HttpOverrides.global = null;
    tester.view.physicalSize = const Size(1280, 840);
    tester.view.devicePixelRatio = 1;
    SharedPreferences.setMockInitialValues({'name': 'Gaming PC'});
    final out = Directory('build/screenshots')..createSync(recursive: true);

    late AppState state;
    late SidekickServer phone;
    late Directory home;
    final phoneId = newDeviceId();

    await tester.runAsync(() async {
      await _loadFonts();
      // A friendly folder name: it shows up in the Files breadcrumb.
      home = Directory(p.join((await Directory.systemTemp.createTemp('sidekick_shots')).path, 'Internal storage'))
        ..createSync();
      for (final dir in ['Camera', 'Download', 'Music', 'Documents']) {
        Directory(p.join(home.path, dir)).createSync();
      }
      File(p.join(home.path, 'Holiday_2026.mp4')).writeAsBytesSync(List.filled(2123456, 0));
      File(p.join(home.path, 'Screenshot_0412.png')).writeAsBytesSync(List.filled(312345, 0));

      phone = SidekickServer(
        identity: Identity.generate(),
        self: () => DeviceInfo(
          id: phoneId,
          name: 'Pixel 9',
          platform: DevicePlatform.android,
          port: phone.port,
          capabilities: const Capabilities(files: true, input: true),
        ),
        trust: TrustStore(),
        files: FileService(home: home.path),
        input: UnsupportedInputInjector(),
        // Pretend remote control is allowed, so Remote shows a live touchpad.
        inputReady: () async => true,
        receiveDir: () async => home.path,
      );
      await phone.start(port: 0, address: InternetAddress.loopbackIPv4);

      state = await AppState.load();
      await state.start();

      final target = DeviceInfo(
        id: phoneId,
        name: 'Pixel 9',
        platform: DevicePlatform.android,
        port: phone.port,
        address: '127.0.0.1',
      );
      final pin = phone.events.where((e) => e is PairRequested).cast<PairRequested>().first;
      await state.requestPairing(target);
      await state.confirmPairing(target, (await pin).request.pin);
    });

    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: SidekickApp(state: state),
      ),
    );

    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    /// Waits until the page has loaded (no spinner left), up to ~10 s.
    Future<void> loaded() async {
      for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> shot(String name, {bool waitForData = false}) async {
      await settle();
      if (waitForData) await loaded();
      // Let entrance animations (list rows, cards) finish.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(out.path, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    // First launch: the welcome flow, once.
    for (var i = 1; find.text('Continue').evaluate().isNotEmpty; i++) {
      await shot('0-welcome-$i');
      await tester.tap(find.text('Continue'));
      await tester.pump(const Duration(milliseconds: 500));
    }
    await shot('0-welcome-last');
    await tester.tap(find.text('Start using Sidekick'));
    expect(state.welcomed, isTrue);
    await shot('1-devices');
    await tester.tap(find.text('Connect device'));
    await shot('1b-devices-connect-menu');
    // QR code pairing: this device's code, then the 6-digit code with its QR
    // (an iPhone asking, so it can scan).
    await tester.tap(find.text('QR code'));
    await shot('1c-qr-code');
    await tester.tap(find.text('Close'));
    await settle();
    await tester.runAsync(
      () => PeerClient(host: '127.0.0.1', port: state.server.port).requestPairing(
        DeviceInfo(id: newDeviceId(), name: 'iPhone 17', platform: DevicePlatform.ios, port: 1),
        myFingerprint: Identity.generate().fingerprint,
      ),
    );
    await shot('1d-pin-with-qr');
    await tester.tap(find.text('Cancel'));
    await settle();
    await tester.tap(find.text('Files').last);
    await shot('2-files', waitForData: true);
    if (find.text('Home').evaluate().isNotEmpty) {
      await tester.tap(find.text('Home'));
      await shot('2b-files-folder', waitForData: true);
    }
    await tester.tap(find.text('Remote').last);
    await shot('3-remote', waitForData: true);
    await tester.tap(find.text('Settings').last);
    await shot('5-settings');
    state.setThemeMode(ThemeMode.dark);
    await tester.tap(find.text('Devices').last);
    await shot('6-devices-dark');

    // Phone layout.
    state.setThemeMode(ThemeMode.light);
    debugForceMobile = true;
    tester.view.physicalSize = const Size(412, 915);
    for (final (tab, name) in [
      ('Devices', 'devices'),
      ('Files', 'files'),
      ('Remote', 'remote'),
      ('Settings', 'settings'),
    ]) {
      await tester.tap(find.text(tab).last);
      await shot('phone-$name', waitForData: name == 'files' || name == 'remote');
    }
    await tester.tap(find.text('Devices').last);
    await settle();
    await tester.tap(find.text('Connect device'));
    await settle();
    await tester.tap(find.text('QR code'));
    await shot('phone-qr-code');
    await tester.tap(find.text('Close'));
    await settle();

    // The welcome flow on a phone.
    state.welcomed = false;
    state.setThemeMode(ThemeMode.light); // also rebuilds
    await shot('phone-welcome-1');
    await tester.tap(find.text('Continue'));
    await shot('phone-welcome-2');
    state.finishWelcome();
    await settle();

    // iPhone Settings: iOS never allows remote control, so no such switch.
    debugHostPlatform = DevicePlatform.ios;
    await tester.tap(find.text('Settings').last);
    await settle();
    final list = find.byType(Scrollable).first;
    await tester.dragUntilVisible(find.text('What paired devices can do here'), list, const Offset(0, -200));
    await shot('iphone-settings-permissions');
    expect(find.text('Control mouse and keyboard'), findsNothing);
    await tester.dragUntilVisible(find.text('Everything is encrypted'), list, const Offset(0, -200));
    await shot('iphone-settings-encryption');
    await tester.ensureVisible(find.textContaining('security code'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('security code'));
    await shot('iphone-security-code');
    await tester.tap(find.text('Done'));
    await tester.dragUntilVisible(find.text('Pure black in dark mode'), list, const Offset(0, -200));
    await shot('iphone-settings-theme');
    state.setThemeColor('teal');
    state.setThemeMode(ThemeMode.dark);
    state.setPureBlack(true);
    await shot('iphone-settings-theme-teal-dark');
    debugHostPlatform = null;

    // The startup animation, a few frames in (desktop, light).
    debugForceMobile = false;
    state.setThemeColor('purple');
    state.setThemeMode(ThemeMode.light);
    state.setPureBlack(false);
    tester.view.physicalSize = const Size(1280, 840);
    await settle(); // let the theme change finish first
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: SidekickApp(state: state, splash: true),
      ),
    );
    // Every 50 ms, for a GIF: startup-00.png, startup-01.png, …
    for (var frame = 0; frame * 50 <= 1800; frame++) {
      await tester.pump(Duration(milliseconds: frame == 0 ? 0 : 50));
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 0.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(out.path, 'startup-${frame.toString().padLeft(2, '0')}.png'))
            .writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
    await tester.pump(const Duration(seconds: 1));

    // The panel the tray / menu-bar icon opens (Windows, Mac).
    tester.view.physicalSize = DesktopWindow.panelSize * 2;
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorSchemeSeed: const Color(0xFF6750A4), fontFamily: 'Roboto'),
          home: TrayPanel(state: state),
        ),
      ),
    );
    await settle();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() async {
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(out.path, 'tray-panel.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
    });

    await tester.runAsync(() async {
      await phone.stop();
      await state.server.stop();
      await state.discovery.stop();
      await home.parent.delete(recursive: true);
    });
    await tester.pumpWidget(const SizedBox());
  });
}

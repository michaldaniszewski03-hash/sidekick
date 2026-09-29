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
import 'package:sidekick/core/crypto.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/core/trust.dart';
import 'package:sidekick/main.dart';
import 'package:sidekick/platform/files.dart';
import 'package:sidekick/platform/input.dart';
import 'package:sidekick/platform/media.dart';
import 'package:sidekick/ui/widgets.dart';

class _FakeMedia implements MediaController {
  bool playing = true;
  @override
  bool get supported => true;
  @override
  Future<MediaStatus> status() async => MediaStatus(
    available: true,
    title: 'Night Drive',
    artist: 'Kavinsky',
    app: 'Spotify',
    status: playing ? PlaybackStatus.playing : PlaybackStatus.paused,
    position: const Duration(seconds: 84),
    duration: const Duration(minutes: 4, seconds: 12),
    canSeek: true,
    volume: 0.64,
  );
  @override
  Future<void> perform(MediaAction action, {Duration? position, double? volume}) async {
    if (action == MediaAction.playPause) playing = !playing;
  }

  @override
  Future<void> dispose() async {}
}

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
      home = await Directory.systemTemp.createTemp('sidekick_shots');
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
          capabilities: const Capabilities(files: true, media: true, input: true),
        ),
        trust: TrustStore(),
        files: FileService(home: home.path),
        media: _FakeMedia(),
        input: UnsupportedInputInjector(),
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

    Future<void> shot(String name) async {
      await settle();
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(out.path, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    await shot('1-devices');
    await tester.tap(find.text('Files').last);
    await shot('2-files');
    if (find.text('Home').evaluate().isNotEmpty) {
      await tester.tap(find.text('Home'));
      await shot('2b-files-folder');
    }
    await tester.tap(find.text('Remote').last);
    await shot('3-remote');
    await tester.tap(find.text('Media').last);
    await shot('4-media');
    await tester.tap(find.text('Settings').last);
    await shot('5-settings');
    state.setThemeMode(ThemeMode.dark);
    await tester.tap(find.text('Media').last);
    await shot('6-media-dark');

    // Phone layout.
    state.setThemeMode(ThemeMode.light);
    debugForceMobile = true;
    tester.view.physicalSize = const Size(412, 915);
    for (final (tab, name) in [('Devices', 'devices'), ('Files', 'files'), ('Remote', 'remote'), ('Media', 'media')]) {
      await tester.tap(find.text(tab).last);
      await shot('phone-$name');
    }

    // iPhone Settings: iOS never allows remote control, so no such switch.
    debugHostPlatform = DevicePlatform.ios;
    await tester.tap(find.text('Settings').last);
    await settle();
    final list = find.byType(Scrollable).first;
    await tester.dragUntilVisible(find.text('What paired devices can do here'), list, const Offset(0, -200));
    await shot('iphone-settings-permissions');
    expect(find.text('Control mouse and keyboard'), findsNothing);
    await tester.dragUntilVisible(
      find.text('Everything between paired devices is encrypted'),
      list,
      const Offset(0, -200),
    );
    await shot('iphone-settings-encryption');
    await tester.ensureVisible(find.textContaining('Tap for security code'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Tap for security code'));
    await shot('iphone-security-code');
    await tester.tap(find.text('Done'));
    await tester.dragUntilVisible(find.text('Pure black in dark mode'), list, const Offset(0, -200));
    await shot('iphone-settings-theme');
    state.setThemeColor('teal');
    state.setThemeMode(ThemeMode.dark);
    state.setPureBlack(true);
    await shot('iphone-settings-theme-teal-dark');
    debugHostPlatform = null;

    await tester.runAsync(() async {
      await phone.stop();
      await state.server.stop();
      await state.discovery.stop();
      await home.delete(recursive: true);
    });
    await tester.pumpWidget(const SizedBox());
  });
}

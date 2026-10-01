// Renders the QR code pairing screens at full resolution, for the website
// and ads. Not part of the normal test run:
//
//   flutter test tool/qr_shots_test.dart --plain-name mac
//   SIDEKICK_CAMERA=feed.png flutter test tool/qr_shots_test.dart --plain-name iphone
//
// * mac: Connect device → QR code on a Mac (1280×800 at 2x).
// * iphone: the QR scanner on an iPhone (393×852 at 3x), with the picture
//   in SIDEKICK_CAMERA where the camera would be.
//
// SIDEKICK_FONTS can point at a folder with Inter-*.ttf (the closest open
// font to Apple's San Francisco, which Sidekick uses on Mac and iPhone);
// without it the text is Roboto. Screenshots land in build/screenshots/.

// This is a test in all but location.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidekick/app_state.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/main.dart';
import 'package:sidekick/ui/qr_pairing.dart';
import 'package:sidekick/ui/widgets.dart';

Future<void> _loadFonts() async {
  final flutterFonts = p.join(
    Platform.environment['FLUTTER_ROOT'] ?? '/home/user/tools/flutter',
    'bin/cache/artifacts/material_fonts',
  );
  Future<ByteData> read(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  await (FontLoader('MaterialIcons')..addFont(read(p.join(flutterFonts, 'MaterialIcons-Regular.otf')))).load();
  final inter = Platform.environment['SIDEKICK_FONTS'];
  // What Flutter asks for on Mac and iPhone (San Francisco), and Roboto.
  for (final family in ['.AppleSystemUIFont', 'CupertinoSystemDisplay', 'CupertinoSystemText', 'Roboto']) {
    final loader = FontLoader(family);
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final file = inter == null
          ? p.join(flutterFonts, 'Roboto-${weight == 'SemiBold' ? 'Medium' : weight}.ttf')
          : p.join(inter, '${family == 'CupertinoSystemDisplay' ? 'InterDisplay' : 'Inter'}-$weight.ttf');
      loader.addFont(read(file));
    }
    await loader.load();
  }
}

void main() {
  final out = Directory('build/screenshots')..createSync(recursive: true);

  /// Starts Sidekick as [name], with nothing paired and nothing nearby.
  Future<AppState> start(WidgetTester tester, String name) async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({'name': name, 'welcomed': true, 'themeColor': 'purple'});
    late AppState state;
    await tester.runAsync(() async {
      await _loadFonts();
      state = await AppState.load();
      await state.start();
      await state.discovery.stop();
      state.addresses = ['192.168.1.24'];
    });
    return state;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> shot(WidgetTester tester, GlobalKey boundary, String name) async {
    await settle(tester);
    final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: tester.view.devicePixelRatio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(out.path, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('mac', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1280 * 2, 800 * 2);
    debugHostPlatform = DevicePlatform.macos;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final state = await start(tester, 'MacBook Pro');
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: SidekickApp(state: state),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Connect device'));
    await settle(tester);
    await tester.tap(find.text('QR code'));
    await shot(tester, boundary, 'ad-mac-qr');
    await tester.tap(find.text('Close'));
    await settle(tester);
    await tester.runAsync(state.server.stop);
    debugHostPlatform = null;
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iphone', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    // The Dynamic Island and the home indicator.
    tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
    tester.view.viewPadding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
    debugForceMobile = true;
    debugHostPlatform = DevicePlatform.ios;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final camera = File(Platform.environment['SIDEKICK_CAMERA'] ?? 'build/screenshots/ad-mac-qr.png');
    debugScannerPreview = (_) => Image.file(camera, fit: BoxFit.cover);
    final state = await start(tester, 'iPhone 17 Pro');
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: SidekickApp(state: state),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Connect device'));
    await settle(tester);
    await tester.tap(find.text('QR code'));
    await settle(tester);
    await tester.tap(find.text('Scan a code'));
    await settle(tester);
    await tester.runAsync(() => precacheImage(FileImage(camera), boundary.currentContext!));
    await shot(tester, boundary, 'ad-iphone-scan');
    await tester.runAsync(state.server.stop);
    debugScannerPreview = null;
    debugForceMobile = false;
    debugHostPlatform = null;
    debugDefaultTargetPlatformOverride = null;
  });
}

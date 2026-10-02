// Renders Sidekick's animations frame by frame (30 fps) for video ads. Not
// part of the normal test run:
//
//   SIDEKICK_FONTS=… flutter test tool/ad_frames_test.dart
//
// * startup: the startup animation on an iPhone (393×852 at 3x).
// * send: an iPhone sending photos to a Mac: waiting for permission, the
//   progress, then Sent.
// * receive: the Mac's Accept/Decline card arriving, then Accept (confetti).
//
// Frames land in build/ad/<scene>/NNN.png. SIDEKICK_FONTS as in
// qr_shots_test.dart. SIDEKICK_THEME picks the color theme (e.g. mono).

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
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
import 'package:sidekick/core/server.dart';
import 'package:sidekick/main.dart';
import 'package:sidekick/ui/transfer_screens.dart';
import 'package:sidekick/ui/widgets.dart';

const _frame = Duration(microseconds: 33333);

Future<void> _loadFonts() async {
  final flutterFonts = p.join(
    Platform.environment['FLUTTER_ROOT'] ?? '/home/user/tools/flutter',
    'bin/cache/artifacts/material_fonts',
  );
  Future<ByteData> read(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  await (FontLoader('MaterialIcons')..addFont(read(p.join(flutterFonts, 'MaterialIcons-Regular.otf')))).load();
  final inter = Platform.environment['SIDEKICK_FONTS'];
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
  Future<AppState> start(WidgetTester tester, String name) async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({
      'name': name,
      'welcomed': true,
      'themeColor': Platform.environment['SIDEKICK_THEME'] ?? 'purple',
    });
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

  /// Saves frames as build/ad/[scene]/NNN.png, numbering on from [first].
  Future<int> frames(WidgetTester tester, GlobalKey key, String scene, int count, {int first = 0}) async {
    final dir = Directory('build/ad/$scene')..createSync(recursive: true);
    for (var i = 0; i < count; i++) {
      await tester.pump(i == 0 && first == 0 ? Duration.zero : _frame);
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(dir.path, '${(first + i).toString().padLeft(3, '0')}.png'))
            .writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
    return first + count;
  }

  void iphone(WidgetTester tester) {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
    tester.view.viewPadding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
    debugForceMobile = true;
    debugHostPlatform = DevicePlatform.ios;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  }

  Future<void> finish(WidgetTester tester, AppState state) async {
    // Let screens that close by themselves (a finished transfer) do so.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(state.server.stop);
    debugForceMobile = false;
    debugHostPlatform = null;
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('startup', (tester) async {
    iphone(tester);
    final state = await start(tester, 'iPhone 17 Pro');
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: SidekickApp(state: state, splash: true),
      ),
    );
    await frames(tester, key, 'startup', 54);
    await finish(tester, state);
  });

  testWidgets('send', (tester) async {
    iphone(tester);
    final state = await start(tester, 'iPhone 17 Pro');
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: SidekickApp(state: state),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final send = OutgoingSend(
      device: PairedDevice(
        id: 'mac',
        name: 'MacBook Pro',
        platform: DevicePlatform.macos,
        token: 't',
        fingerprint: 'f',
        key: 'k',
      ),
      names: ['IMG_2041.HEIC', 'IMG_2042.HEIC', 'Trip.mov'],
      total: 47100000,
    )..phase = SendPhase.waiting;
    final context = tester.element(find.byType(Scaffold).first);
    showSendingScreen(context, send).ignore();
    var n = await frames(tester, key, 'send', 60);
    send.phase = SendPhase.sending;
    for (var i = 0; i < 45; i++) {
      send
        ..done = (send.total * Curves.easeInOut.transform(i / 44)).round()
        ..current = (i * 3 ~/ 45).clamp(0, 2)
        ..notifyListeners();
      n = await frames(tester, key, 'send', 1, first: n);
    }
    send
      ..phase = SendPhase.done
      ..notifyListeners();
    await frames(tester, key, 'send', 36, first: n);
    await finish(tester, state);
  });

  testWidgets('receive', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1280 * 2, 800 * 2);
    debugHostPlatform = DevicePlatform.macos;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final state = await start(tester, 'MacBook Pro');
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: SidekickApp(state: state),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final offer = TransferOffer(
      id: 'o',
      from: TrustedPeer(
        id: 'p',
        name: 'iPhone 17 Pro',
        platform: DevicePlatform.ios,
        token: 't',
        fingerprint: 'f',
        key: 'k',
      ),
      files: const [
        OfferedFile('IMG_2041.HEIC', 3200000),
        OfferedFile('IMG_2042.HEIC', 2900000),
        OfferedFile('Trip.mov', 41000000),
      ],
    );
    final context = tester.element(find.byType(Scaffold).first);
    showIncomingOffer(context, offer).ignore();
    final n = await frames(tester, key, 'receive', 66);
    await tester.tap(find.text('Accept'));
    // The files arrive as the iPhone sends them (its progress runs over 45
    // frames from a few frames after Accept): the same pace here.
    var m = await frames(tester, key, 'receive', 3, first: n);
    var sent = 0;
    var file = 0;
    for (var i = 0; i < 47; i++) {
      final target = i >= 44 ? offer.totalBytes : (offer.totalBytes * Curves.easeInOut.transform(i / 44)).round();
      // Finish files as the running total passes their ends.
      var end = 0;
      for (var k = 0; k <= file && k < offer.files.length; k++) {
        end += offer.files[k].size;
      }
      while (file < offer.files.length && target >= end) {
        offer.debugReceived(offer.files[file].size, fileDone: true);
        sent = end;
        file++;
        if (file < offer.files.length) end += offer.files[file].size;
      }
      if (target > sent) {
        offer.debugReceived(target - sent);
        sent = target;
      }
      m = await frames(tester, key, 'receive', 1, first: m);
    }
    await finish(tester, state);
  });
}

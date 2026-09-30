// Renders the send and receive screens in each phase to PNG:
//
//   flutter test tool/transfer_shots_test.dart
//
// Screenshots land in build/screenshots/.

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:sidekick/app_state.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/ui/transfer_screens.dart';

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
  testWidgets('transfer screens', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.runAsync(_loadFonts);
    final out = Directory('build/screenshots')..createSync(recursive: true);
    final key = GlobalKey();
    final theme = ThemeData(colorSchemeSeed: const Color(0xFF6750A4), fontFamily: 'Roboto');

    Future<void> frame(String name) async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 0.75);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(out.path, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    Future<void> shot(String name) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(out.path, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    final mac = PairedDevice(
      id: 'mac',
      name: 'Pixel 9',
      platform: DevicePlatform.android,
      token: 't',
      fingerprint: 'f',
      key: 'k',
    );
    for (final phase in SendPhase.values) {
      final send = OutgoingSend(device: mac, names: ['IMG_2041.HEIC', 'IMG_2042.HEIC', 'Trip.mov'], total: 47100000)
        ..phase = phase
        ..done = 31000000
        ..current = 2
        ..error = phase == SendPhase.failed ? "Can't reach Pixel 9." : null;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: theme,
            debugShowCheckedModeBanner: false,
            home: SendingScreen(send: send),
          ),
        ),
      );
      await shot('send_${phase.name}');
    }

    // Also dark mode with the black-and-white theme: icons on the theme's
    // gradient must stay visible there.
    final monoDark = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF757575),
        brightness: Brightness.dark,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      ),
      fontFamily: 'Roboto',
    );
    for (final (t, suffix) in [(theme, ''), (monoDark, '_mono_dark')]) {
      final offer = TransferOffer(
        id: 'o',
        from: TrustedPeer(
          id: 'p',
          name: "Ana's iPhone",
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
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: t,
            debugShowCheckedModeBanner: false,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(onPressed: () => showIncomingOffer(context, offer), child: const Text('open')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      if (suffix.isEmpty) {
        // The card arriving, frame by frame (receive-anim-NN.png, 60 ms apart).
        for (var f = 0; f < 30; f++) {
          await tester.pump(Duration(milliseconds: f == 0 ? 0 : 60));
          await frame('receive-anim-${f.toString().padLeft(2, '0')}');
        }
      }
      await shot('receive_asking$suffix');
      await tester.tap(find.text('Accept'));
      if (suffix.isEmpty) {
        for (var f = 0; f < 12; f++) {
          await tester.pump(Duration(milliseconds: f == 0 ? 0 : 80));
          await frame('receive-accept-${f.toString().padLeft(2, '0')}');
        }
      }
      await shot('receive_receiving$suffix');
      await tester.pumpWidget(const SizedBox());
    }
    await tester.pumpWidget(const SizedBox());
  });
}

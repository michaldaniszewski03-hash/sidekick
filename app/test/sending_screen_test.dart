import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sidekick/app_state.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/ui/transfer_screens.dart';

void main() {
  final mac = PairedDevice(
    id: 'mac',
    name: 'Mac',
    platform: DevicePlatform.macos,
    token: 't',
    fingerprint: 'f',
    key: 'k',
  );

  for (final (phase, label) in [
    (SendPhase.connecting, 'Cancel'),
    (SendPhase.waiting, 'Cancel'),
    (SendPhase.sending, 'Hide'),
    (SendPhase.done, 'Close'),
    (SendPhase.declined, 'Close'),
    (SendPhase.failed, 'Close'),
  ]) {
    testWidgets('$label closes the sending screen ($phase)', (tester) async {
      final send = OutgoingSend(device: mac, names: ['a.jpg'], total: 100)..phase = phase;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(onPressed: () => showSendingScreen(context, send), child: const Text('open')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SendingScreen), findsOneWidget);
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SendingScreen), findsNothing);
    });
  }

  testWidgets('Close closes the sending screen even with a dialog on top of it', (tester) async {
    final send = OutgoingSend(device: mac, names: ['a.jpg'], total: 100)..phase = SendPhase.sending;
    late BuildContext home;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            home = context;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );
    unawaited(showSendingScreen(home, send));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // Something else opens on top, then the send finishes and closes by itself.
    unawaited(
      showDialog<void>(
        context: home,
        builder: (_) => const AlertDialog(title: Text('Other')),
      ),
    );
    await tester.pump();
    send.phase = SendPhase.done;
    send.notifyListeners();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(SendingScreen), findsNothing, reason: 'its own route closed, not the dialog');
    expect(find.text('Other'), findsOneWidget);
  });
}

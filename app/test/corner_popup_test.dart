import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sidekick/core/models.dart';
import 'package:sidekick/core/server.dart';
import 'package:sidekick/ui/corner_popup.dart';

TransferOffer _offer() => TransferOffer(
  id: 'o',
  from: TrustedPeer(
    id: 'p',
    name: "Ana's iPhone",
    platform: DevicePlatform.ios,
    token: 't',
    fingerprint: 'f',
    key: 'k',
  ),
  files: const [OfferedFile('IMG_2041.HEIC', 3200000), OfferedFile('Trip.mov', 41000000)],
);

/// The exit animation, from its first frame to the end.
Future<void> fadeOut(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(CornerPopup.exit);
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  Future<void> pump(WidgetTester tester, TransferOffer offer, VoidCallback onDone) => tester.pumpWidget(
    MaterialApp(
      home: CornerPopup(offer: offer, onDone: onDone),
    ),
  );

  testWidgets('accept, then it closes by itself once the files are in', (tester) async {
    final offer = _offer();
    var done = false;
    await pump(tester, offer, () => done = true);
    expect(find.text("Ana's iPhone"), findsOneWidget);
    expect(find.text('wants to send you 2 files'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pump();
    expect(await offer.answer, OfferAnswer.accepted);
    offer.debugReceived(3200000, fileDone: true);
    await tester.pump();
    expect(done, isFalse, reason: 'one file still to come');
    offer.debugReceived(41000000, fileDone: true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(done, isFalse, reason: 'shows the check for a moment');
    await tester.pump(const Duration(milliseconds: 200));
    await fadeOut(tester);
    expect(done, isTrue);
  });

  testWidgets('decline closes it right away', (tester) async {
    final offer = _offer();
    var done = false;
    await pump(tester, offer, () => done = true);
    await tester.tap(find.text('Decline'));
    await tester.pump();
    expect(await offer.answer, OfferAnswer.declined);
    await fadeOut(tester);
    expect(done, isTrue);
  });

  testWidgets('answered from elsewhere: follows along', (tester) async {
    final offer = _offer();
    var done = false;
    await pump(tester, offer, () => done = true);
    offer.decline();
    await tester.pump();
    await fadeOut(tester);
    expect(done, isTrue);
  });

  testWidgets('reduced motion: no exit animation', (tester) async {
    final offer = _offer();
    var done = false;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: CornerPopup(offer: offer, onDone: () => done = true),
        ),
      ),
    );
    await tester.tap(find.text('Decline'));
    await tester.pump();
    await tester.pump();
    expect(done, isTrue);
  });
}

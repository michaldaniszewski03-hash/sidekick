@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sidekick/platform/input.dart';
import 'package:sidekick/platform/media.dart';

/// Starts the real PowerShell media helper. Runs on the Windows CI machine,
/// which has no media playing, so it checks that the helper starts and
/// answers rather than what it reports.
void main() {
  test('media helper starts and answers status', () async {
    final media = WindowsMediaController(UnsupportedInputInjector());
    final reply = await media.helper.call('status');
    // ignore: avoid_print
    print('helper reply: $reply\ninit errors: ${media.helper.initErrors}\nlast error: ${media.helper.lastError}');
    expect(reply, isNotNull, reason: media.helper.lastError);
    expect(reply!['ok'], isTrue, reason: '$reply');
    expect(
      media.helper.initErrors.where((e) => e.startsWith('media:')),
      isEmpty,
      reason: 'Media sessions failed to load: ${media.helper.initErrors}',
    );

    // A second call reuses the running helper and is quick.
    final watch = Stopwatch()..start();
    expect((await media.helper.call('status'))?['ok'], isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));

    final status = await media.status();
    expect(status.nowPlaying, isTrue);
    await media.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

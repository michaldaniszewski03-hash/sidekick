@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sidekick/platform/input.dart';
import 'package:sidekick/platform/media.dart';

/// Starts the real PowerShell media helper on the Windows CI machine, which
/// has no media playing, and checks that it starts and answers. On failure
/// the helper's step-by-step trace is printed.
void main() {
  test('media helper starts and answers', () async {
    final helper = PowerShellHelper(trace: true, callTimeout: const Duration(seconds: 60));
    addTearDown(helper.dispose);
    String diagnostics() =>
        'last error: ${helper.lastError}\ninit errors: ${helper.initErrors}\ntrace:\n${helper.stderrLines.join('\n')}';

    final ping = await helper.call('ping');
    expect(ping?['ok'], isTrue, reason: diagnostics());

    final watch = Stopwatch()..start();
    final status = await helper.call('status');
    // ignore: avoid_print
    print('status took ${watch.elapsed}: $status\n${diagnostics()}');
    expect(status?['ok'], isTrue, reason: diagnostics());
    expect(helper.initErrors.where((e) => e.startsWith('media:')), isEmpty, reason: diagnostics());

    // Later calls reuse the running helper and must fit the app's timeout.
    watch.reset();
    expect((await helper.call('status'))?['ok'], isTrue, reason: diagnostics());
    expect(watch.elapsed, lessThan(const Duration(seconds: 8)), reason: diagnostics());
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('controller reports status through the helper', () async {
    final media = WindowsMediaController(UnsupportedInputInjector());
    addTearDown(media.dispose);
    final status = await media.status();
    expect(status.note, isNull, reason: 'helper error: ${media.helper.lastError}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

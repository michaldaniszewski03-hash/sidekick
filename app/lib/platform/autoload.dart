import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Auto-load (Settings, Windows and Mac, on by default): Sidekick starts by
/// itself when you log in, straight into the tray / menu bar.
///
/// * Windows: a `Sidekick` value under HKCU\…\CurrentVersion\Run, running
///   it with `--hidden` (the runner then never shows the window).
/// * Mac: a LaunchAgent (`~/Library/LaunchAgents/dev.sidekick.sidekick.plist`)
///   that runs it with `SIDEKICK_HIDDEN=1` (it then hides to the menu bar).
///
/// Written again at every start while on, so it follows the app if it
/// moves. Phones can't start apps at login.
abstract final class AutoLoad {
  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// The arguments Sidekick was started with (main's).
  static List<String> args = const [];

  /// Started at login: no window, no splash, no startup chime.
  static bool get launchedHidden => args.contains('--hidden') || Platform.environment['SIDEKICK_HIDDEN'] == '1';

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  static String get _agent =>
      p.join(Platform.environment['HOME'] ?? '', 'Library', 'LaunchAgents', 'dev.sidekick.sidekick.plist');

  /// Turns it on or off. Never throws.
  static Future<void> apply(bool on) async {
    try {
      if (Platform.isWindows) {
        final exe = Platform.resolvedExecutable;
        final result = on
            ? await Process.run('reg', [
                'add',
                _runKey,
                '/v',
                'Sidekick',
                '/t',
                'REG_SZ',
                '/d',
                '"$exe" --hidden',
                '/f',
              ])
            : await Process.run('reg', ['delete', _runKey, '/v', 'Sidekick', '/f']);
        // Deleting what isn't there "fails"; that's fine.
        if (on && result.exitCode != 0) debugPrint('Sidekick: auto-load: ${result.stderr}');
      } else if (Platform.isMacOS) {
        final file = File(_agent);
        if (!on) {
          if (file.existsSync()) await file.delete();
          return;
        }
        await file.parent.create(recursive: true);
        await file.writeAsString(_plist(Platform.resolvedExecutable));
      }
    } catch (e) {
      debugPrint('Sidekick: auto-load: $e');
    }
  }

  static String _xml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static String _plist(String executable) =>
      '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.sidekick.sidekick</string>
	<key>ProgramArguments</key>
	<array>
		<string>${_xml(executable)}</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>SIDEKICK_HIDDEN</key>
		<string>1</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
''';
}

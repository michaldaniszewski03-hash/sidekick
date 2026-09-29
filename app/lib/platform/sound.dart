import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Plays Sidekick's startup chime on a Mac (Settings → Startup sound).
///
/// Uses the system's `afplay`, so there's no audio plugin and nothing native
/// to maintain; Sidekick isn't sandboxed, so it may run it. Never throws: a
/// missing chime is not worth an error.
Future<void> playStartupSound() async {
  if (!Platform.isMacOS) return;
  try {
    final data = await rootBundle.load('assets/sounds/startup.wav');
    final file = File(p.join(Directory.systemTemp.path, 'sidekick-startup.wav'));
    if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    await Process.start('/usr/bin/afplay', ['-v', '0.6', file.path], mode: ProcessStartMode.detached);
  } catch (_) {
    // No sound, no problem.
  }
}

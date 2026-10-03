import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Plays Sidekick's sounds on every platform, with what the system already
/// has: no audio plugin. The sounds come from tool/sounds/ (prepared by
/// tool/prepare_sounds.py): startup, a request arriving, and a request
/// accepted or declined. Settings → Sound turns them all off.
///
/// * Mac: AVAudioPlayer (then NSSound, then `afplay`).
/// * Windows: `PlaySound` from winmm.dll.
/// * iPhone: AVAudioPlayer on the media volume, mixed with other audio.
/// * Android: MediaPlayer on the media volume.
///
/// Never throws: a missing chime is not worth an error.
Future<void> playStartupSound() => _play('startup');

/// A device wants to send files here (the Accept/Decline card appears).
Future<void> playRequestSound() => _play('request');

/// A request was accepted (tapped here, or the other device's answer).
Future<void> playAcceptSound() => _play('accept');

/// A request was declined (tapped here, or the other device's answer).
Future<void> playDeclineSound() => _play('decline');

/// Another device pinged this one: loud, and on Android on the alarm
/// volume, so it's heard even on silent. Plays whatever Settings → Sound
/// says: someone asked for it.
Future<void> playPingSound() => _play('ping', loud: true);

Future<void> _play(String name, {bool loud = false}) async {
  try {
    final path = await _soundFile(name);
    if (Platform.isMacOS) {
      var played = false;
      try {
        played = await const MethodChannel('sidekick/macos').invokeMethod<bool>('playSound', {'path': path}) ?? false;
      } catch (_) {}
      if (!played) await Process.start('/usr/bin/afplay', [path], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      _playOnWindows(path);
    } else if (Platform.isIOS) {
      await const MethodChannel('sidekick/ios').invokeMethod('playSound', {'path': path});
    } else if (Platform.isAndroid) {
      await const MethodChannel('sidekick/android').invokeMethod('playSound', {'path': path, 'loud': loud});
    }
  } catch (e) {
    // No sound, no problem; but say why in the log.
    debugPrint('Sidekick: $name sound failed: $e');
  }
}

/// The sound as a file the system players can open (written once).
Future<String> _soundFile(String name) async {
  final data = await rootBundle.load('assets/sounds/$name.wav');
  final file = File(p.join((await _soundDir()).path, 'sidekick-$name.wav'));
  if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
    await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
  }
  return file.path;
}

/// Where the sound files go. On the Mac the "temporary" directory is
/// `~/Library/Caches/<app id>`, which nothing creates: writing there failed,
/// so the Mac never played a sound. Created here, with the system's temp
/// folder if even that fails.
Future<Directory> _soundDir() async {
  try {
    return await (await getTemporaryDirectory()).create(recursive: true);
  } catch (_) {
    return Directory.systemTemp;
  }
}

typedef _PlaySoundNative = Int32 Function(Pointer<Utf16> sound, IntPtr module, Uint32 flags);
typedef _PlaySoundDart = int Function(Pointer<Utf16> sound, int module, int flags);

/// Kept for the life of the app: an asynchronous PlaySound may still be
/// reading the name after the call returns.
final Map<String, Pointer<Utf16>> _windowsPaths = {};

void _playOnWindows(String path) {
  const sndAsync = 0x0001, sndNoDefault = 0x0002, sndFilename = 0x00020000;
  final playSound = DynamicLibrary.open('winmm.dll').lookupFunction<_PlaySoundNative, _PlaySoundDart>('PlaySoundW');
  final name = _windowsPaths[path] ??= path.toNativeUtf16();
  playSound(name, 0, sndFilename | sndAsync | sndNoDefault);
}

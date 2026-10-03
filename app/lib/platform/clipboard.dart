import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Notices what you copy on this device, to share it with paired devices
/// (Settings → Share clipboard). Only text, and never what a password
/// manager marks as secret.
///
/// * Windows: the clipboard's sequence number (`GetClipboardSequenceNumber`),
///   checked a few times a second; skips content marked
///   `ExcludeClipboardContentFromMonitorProcessing` (password managers).
/// * Mac: `NSPasteboard.changeCount` (`clipboardState` on `sidekick/macos`);
///   skips `org.nspasteboard.ConcealedType` / `TransientType`.
/// * Android: the clipboard's change listener (`sidekick/clipboard`), which
///   Android only calls while Sidekick is on screen; skips content marked
///   sensitive (Android 13+).
/// * iPhone: never by itself: reading the clipboard makes iOS ask "Allow
///   Paste?". The Send clipboard button does it instead ([automatic] false).
class ClipboardWatcher {
  ClipboardWatcher(this.onCopied);

  /// Called with the text just copied here.
  final void Function(String text) onCopied;

  /// Shares what you copy by itself (everything but iPhone).
  static bool get automatic => Platform.isWindows || Platform.isMacOS || Platform.isAndroid;

  static const _mac = MethodChannel('sidekick/macos');
  static const _android = MethodChannel('sidekick/clipboard');

  Timer? _timer;
  int? _lastCount;

  void start() {
    if (_timer != null) return;
    if (Platform.isWindows) {
      _lastCount = _Win.sequence();
      _timer = Timer.periodic(const Duration(milliseconds: 600), (_) => _checkWindows());
    } else if (Platform.isMacOS) {
      unawaited(_macState().then((s) => _lastCount = s?.count));
      _timer = Timer.periodic(const Duration(milliseconds: 600), (_) => _checkMac());
    } else if (Platform.isAndroid) {
      _android.setMethodCallHandler((call) async {
        if (call.method == 'changed' && call.arguments is Map && (call.arguments as Map)['sensitive'] != true) {
          await _read();
        }
        return null;
      });
      unawaited(_android.invokeMethod<void>('watch', {'on': true}).catchError((Object _) {}));
      // A placeholder so stop() knows it's running.
      _timer = Timer(Duration.zero, () {});
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (Platform.isAndroid) {
      _android.setMethodCallHandler(null);
      unawaited(_android.invokeMethod<void>('watch', {'on': false}).catchError((Object _) {}));
    }
  }

  void _checkWindows() {
    final count = _Win.sequence();
    if (count == _lastCount) return;
    _lastCount = count;
    if (_Win.concealed()) return;
    unawaited(_read());
  }

  Future<void> _checkMac() async {
    final state = await _macState();
    if (state == null || state.count == _lastCount) return;
    _lastCount = state.count;
    if (!state.concealed) await _read();
  }

  static Future<({int count, bool concealed})?> _macState() async {
    try {
      final s = await _mac.invokeMapMethod<String, Object?>('clipboardState');
      if (s == null) return null;
      return (count: (s['count'] as num?)?.toInt() ?? 0, concealed: s['concealed'] == true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _read() async {
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (text != null && text.trim().isNotEmpty) onCopied(text);
    } catch (e) {
      debugPrint('Sidekick: reading the clipboard: $e');
    }
  }
}

/// user32's clipboard counter and format checks, without a plugin.
abstract final class _Win {
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _sequence = _user32.lookupFunction<Uint32 Function(), int Function()>('GetClipboardSequenceNumber');
  static final _register = _user32.lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>(
    'RegisterClipboardFormatW',
  );
  static final _available = _user32.lookupFunction<Int32 Function(Uint32), int Function(int)>(
    'IsClipboardFormatAvailable',
  );

  /// Formats password managers add so clipboard tools leave the copy alone.
  static final List<int> _secret = [
    for (final name in ['ExcludeClipboardContentFromMonitorProcessing', 'Clipboard Viewer Ignore'])
      using((arena) => _register(name.toNativeUtf16(allocator: arena))),
  ];

  static int sequence() => _sequence();

  static bool concealed() => _secret.any((f) => f != 0 && _available(f) != 0);
}

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
///   Android only calls while Sidekick is on screen, and on coming back to
///   Sidekick the clipboard's timestamp (`stamp`, read without the "pasted
///   from your clipboard" toast) for copies made meanwhile; skips content
///   marked sensitive (Android 13+). Android lets no app read it in the
///   background.
/// * iPhone: `UIPasteboard.changeCount` (`clipboardState` on `sidekick/ios`,
///   no prompt), checked every second while Sidekick is on screen; iOS lets
///   no app read the clipboard in the background, and asks "Allow Paste?"
///   for each read unless Settings → Sidekick → Paste from Other Apps is
///   Allow.
class ClipboardWatcher {
  ClipboardWatcher(this.onCopied);

  /// Called with the text just copied here.
  final void Function(String text) onCopied;

  /// Shares what you copy by itself.
  static bool get automatic => Platform.isWindows || Platform.isMacOS || Platform.isAndroid || Platform.isIOS;

  static const _mac = MethodChannel('sidekick/macos');
  static const _android = MethodChannel('sidekick/clipboard');
  static const _ios = MethodChannel('sidekick/ios');

  Timer? _timer;
  int? _lastCount;
  AppLifecycleListener? _lifecycle;

  static bool get _onScreen => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

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
      unawaited(_androidStamp().then((s) => _lastCount ??= s?.stamp));
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(_checkAndroid()));
      // A placeholder so stop() knows it's running.
      _timer = Timer(Duration.zero, () {});
    } else if (Platform.isIOS) {
      unawaited(_iosState().then((s) => _lastCount ??= s?.count));
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _checkIos());
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
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

  /// Copied in another app while Sidekick was in the background.
  Future<void> _checkAndroid() async {
    final s = await _androidStamp();
    if (s == null || s.stamp == 0 || s.stamp == _lastCount) return;
    _lastCount = s.stamp;
    if (!s.sensitive) await _read();
  }

  static Future<({int stamp, bool sensitive})?> _androidStamp() async {
    try {
      final s = await _android.invokeMapMethod<String, Object?>('stamp');
      if (s == null) return null;
      return (stamp: (s['stamp'] as num?)?.toInt() ?? 0, sensitive: s['sensitive'] == true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkIos() async {
    // In the background iOS hands out nothing; on screen it's checked.
    if (!_onScreen) return;
    final s = await _iosState();
    if (s == null || s.count == _lastCount) return;
    _lastCount = s.count;
    if (s.hasText) await _read();
  }

  static Future<({int count, bool hasText})?> _iosState() async {
    try {
      final s = await _ios.invokeMapMethod<String, Object?>('clipboardState');
      if (s == null) return null;
      return (count: (s['count'] as num?)?.toInt() ?? 0, hasText: s['hasText'] == true);
    } catch (_) {
      return null;
    }
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

/// iPhone: Sidekick's page in Settings, where Paste from Other Apps → Allow
/// stops iOS asking "Allow Paste?" each time.
Future<void> openIosAppSettings() async {
  try {
    await const MethodChannel('sidekick/ios').invokeMethod<void>('openSettings');
  } catch (_) {}
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps Sidekick's secrets (this device's private key, pairing tokens and
/// pairing keys) out of plain app settings:
/// * iPhone: the Keychain; Android: the Keystore; Windows: DPAPI storage.
/// * Mac: a file only your macOS account can read (like SSH keys). The Mac
///   app isn't signed with a paid Apple account, so the Keychain would ask
///   for your password again and again; [file] avoids that.
///
/// Secrets saved by older versions in app settings are moved over once. If secure storage doesn't work on this device,
/// secrets stay in app settings so Sidekick keeps working, and [secure]
/// says so (Settings shows it).
class SecretStore {
  SecretStore(this._prefs, {FlutterSecureStorage? storage, this.file})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            // Unused on a Mac (see [file]).
            mOptions: MacOsOptions(
              usesDataProtectionKeychain: false,
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final SharedPreferences _prefs;
  final FlutterSecureStorage _storage;

  /// Where secrets live instead of the system store (Mac).
  final File? file;
  Future<void> _writes = Future.value();
  Map<String, String>? _fileSecrets;

  /// False once secure storage failed and secrets fell back to app settings.
  bool secure = true;

  static String _key(String name) => 'sidekick.$name';
  static String _fallbackKey(String name) => 'secret.$name';

  /// Reads a secret. [legacy] reads where older versions kept it; a value
  /// found there is moved into secure storage.
  Future<String?> read(String name, {String? Function()? legacy, Future<void> Function()? removeLegacy}) async {
    if (file != null) return _readFromFile(name, legacy: legacy, removeLegacy: removeLegacy);
    try {
      final value = await _storage.read(key: _key(name));
      if (value != null) return value;
    } catch (_) {
      secure = false;
    }
    final fallback = _prefs.getString(_fallbackKey(name));
    final old = fallback ?? legacy?.call();
    if (old != null && secure) {
      await write(name, old);
      await _writes;
      if (secure) {
        await _prefs.remove(_fallbackKey(name));
        await removeLegacy?.call();
      }
    }
    return old;
  }

  /// Saves a secret. Writes happen in order, so the latest always wins.
  Future<void> write(String name, String value) => _writes = _writes.then((_) async {
    if (file != null) {
      (await _loadFile())[name] = value;
      await _saveFile();
      return;
    }
    try {
      await _storage.write(key: _key(name), value: value);
      // Read it back: some keychains accept writes they never store.
      if (await _storage.read(key: _key(name)) != value) throw StateError('Secure storage lost the value');
      secure = true;
      if (_prefs.containsKey(_fallbackKey(name))) await _prefs.remove(_fallbackKey(name));
    } catch (_) {
      secure = false;
      await _prefs.setString(_fallbackKey(name), value);
    }
  });

  /// Waits for pending writes (tests, shutdown).
  Future<void> flush() => _writes;

  // ------------------------------------------------------------ file (Mac)

  Future<String?> _readFromFile(
    String name, {
    String? Function()? legacy,
    Future<void> Function()? removeLegacy,
  }) async {
    final secrets = await _loadFile();
    final value = secrets[name];
    if (value != null) return value;
    // Never read the Mac keychain, not even to move keys from 1.0: every
    // read shows a password prompt for this unsigned app. Keys from 1.0
    // stay unused; the Mac makes a new identity and pairs again once.
    final old = _prefs.getString(_fallbackKey(name)) ?? legacy?.call();
    if (old != null) {
      await write(name, old);
      await _writes;
      await _prefs.remove(_fallbackKey(name));
      await removeLegacy?.call();
    }
    return old;
  }

  /// Kept for callers; the Mac file store never reads the keychain.
  Future<void> finishedMoving() async {}

  Future<Map<String, String>> _loadFile() async {
    final cached = _fileSecrets;
    if (cached != null) return cached;
    final map = <String, String>{};
    try {
      final f = file!;
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) {
          for (final e in decoded.entries) {
            if (e.value is String) map['${e.key}'] = e.value as String;
          }
        }
      }
    } catch (_) {
      // Unreadable: start over (devices will ask to pair again).
    }
    return _fileSecrets = map;
  }

  /// Writes the file readable by this user only (0600), via a temporary
  /// file so a crash never leaves half a file behind.
  Future<void> _saveFile() async {
    final f = file!;
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString('');
    await _restrict(tmp);
    await tmp.writeAsString(jsonEncode(_fileSecrets ?? const {}), flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> _restrict(File f) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('/bin/chmod', ['600', f.path]);
    } catch (_) {}
  }
}

import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps Sidekick's secrets (this device's private key, pairing tokens and
/// pairing keys) in the system's secure storage: the Keychain on iPhone and
/// Mac, the Android Keystore, and DPAPI-encrypted storage on Windows.
///
/// Secrets saved by older versions in plain app settings are moved over the
/// first time they're read. If secure storage doesn't work on this device,
/// secrets stay in app settings so Sidekick keeps working, and [secure]
/// says so (Settings shows it).
class SecretStore {
  SecretStore(this._prefs, {FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            // The data-protection keychain needs a paid Apple team; the
            // login keychain works for this self-signed app. macOS may ask
            // once after an update whether Sidekick may read it.
            mOptions: MacOsOptions(
              usesDataProtectionKeychain: false,
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final SharedPreferences _prefs;
  final FlutterSecureStorage _storage;
  Future<void> _writes = Future.value();

  /// False once secure storage failed and secrets fell back to app settings.
  bool secure = true;

  static String _key(String name) => 'sidekick.$name';
  static String _fallbackKey(String name) => 'secret.$name';

  /// Reads a secret. [legacy] reads where older versions kept it; a value
  /// found there is moved into secure storage.
  Future<String?> read(String name, {String? Function()? legacy, Future<void> Function()? removeLegacy}) async {
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
}

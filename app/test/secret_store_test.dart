import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidekick/platform/secret_store.dart';

/// Secure storage that always fails, like a denied keychain prompt.
class BrokenStorage extends FlutterSecureStorage {
  const BrokenStorage();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw PlatformException(code: 'denied');

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw PlatformException(code: 'denied');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('moves secrets from app settings into secure storage', () async {
    SharedPreferences.setMockInitialValues({'identity': 'old-key'});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SecretStore(prefs);

    final value = await store.read(
      'identity',
      legacy: () => prefs.getString('identity'),
      removeLegacy: () => prefs.remove('identity'),
    );
    expect(value, 'old-key');
    expect(store.secure, isTrue);
    expect(prefs.containsKey('identity'), isFalse, reason: 'no plain copy left behind');
    expect(await const FlutterSecureStorage().read(key: 'sidekick.identity'), 'old-key');

    await store.write('identity', 'new-key');
    await store.flush();
    expect(await SecretStore(prefs).read('identity'), 'new-key');
  });

  test('falls back to app settings when secure storage fails', () async {
    SharedPreferences.setMockInitialValues({'identity': 'old-key'});
    final prefs = await SharedPreferences.getInstance();
    final store = SecretStore(prefs, storage: const BrokenStorage());

    expect(
      await store.read(
        'identity',
        legacy: () => prefs.getString('identity'),
        removeLegacy: () => prefs.remove('identity'),
      ),
      'old-key',
    );
    expect(store.secure, isFalse);
    expect(prefs.getString('identity'), 'old-key', reason: 'nothing lost');

    await store.write('paired', '[]');
    await store.flush();
    expect(prefs.getString('secret.paired'), '[]');
    expect(await store.read('paired'), '[]');
  });
}

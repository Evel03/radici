// Caché del idioma en SharedPreferences (con el almacenamiento en memoria del
// plugin): sobrevive a un "reinicio" y tolera valores raros.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/features/settings/data/language_cache.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('vacía al principio', () async {
    final cache = await SharedPreferencesLanguageCache.load();
    expect(cache.read(), isNull);
  });

  test('lo escrito se lee enseguida y después de reiniciar', () async {
    final cache = await SharedPreferencesLanguageCache.load();
    await cache.write((userId: 'user-1', language: AppLanguage.es));
    expect(cache.read(), (userId: 'user-1', language: AppLanguage.es));

    // Arranque en frío: otra instancia lee lo guardado.
    final restarted = await SharedPreferencesLanguageCache.load();
    expect(restarted.read(), (userId: 'user-1', language: AppLanguage.es));
  });

  test('borrar', () async {
    final cache = await SharedPreferencesLanguageCache.load();
    await cache.write((userId: 'user-1', language: AppLanguage.en));
    await cache.clear();
    expect(cache.read(), isNull);
    expect((await SharedPreferencesLanguageCache.load()).read(), isNull);
  });

  test('un valor que no se entiende es como no tener nada', () async {
    for (final raw in <Object>['', 'es', 'es:', ':user-1', 'fr:user-1', 42]) {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
            SharedPreferencesLanguageCache.key: raw,
          });
      final cache = await SharedPreferencesLanguageCache.load();
      expect(cache.read(), isNull, reason: '$raw');
    }
  });

  test('el id del usuario puede tener ":" (solo separa el primero)', () async {
    final cache = await SharedPreferencesLanguageCache.load();
    await cache.write((userId: 'a:b', language: AppLanguage.it));
    expect(cache.read(), (userId: 'a:b', language: AppLanguage.it));
  });
}

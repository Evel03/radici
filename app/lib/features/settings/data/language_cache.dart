// Idioma de la interfaz guardado en el dispositivo para quien tiene la
// sesión. Sirve para el arranque en frío: la interfaz sale en ese idioma
// desde el primer cuadro, antes de leer el perfil (que después lo confirma o
// lo corrige). Lleva el id del usuario y se borra al salir: antes del login
// manda el idioma del dispositivo.
//
// Es solo una ayuda: si el almacenamiento falla, la app sigue igual y el
// idioma llega con el perfil.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/app_language.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Idioma guardado y de qué usuario es.
typedef CachedLanguage = ({String userId, AppLanguage language});

abstract interface class LanguageCache {
  /// Lo guardado, o null. Síncrono: se lee al armar la primera pantalla.
  CachedLanguage? read();

  /// Nunca falla (un error de almacenamiento se ignora).
  Future<void> write(CachedLanguage value);

  /// Nunca falla (un error de almacenamiento se ignora).
  Future<void> clear();
}

/// main.dart lo reemplaza por la caché persistente, ya cargada antes de
/// runApp. Por defecto (tests, o si no se pudo cargar) vive en memoria.
final languageCacheProvider = Provider<LanguageCache>(
  (ref) => MemoryLanguageCache(),
);

class MemoryLanguageCache implements LanguageCache {
  MemoryLanguageCache([this._value]);

  CachedLanguage? _value;

  @override
  CachedLanguage? read() => _value;

  @override
  Future<void> write(CachedLanguage value) async => _value = value;

  @override
  Future<void> clear() async => _value = null;
}

/// En SharedPreferences (localStorage en la web), con una sola clave cuyo
/// valor es `código:id del usuario`: idioma y usuario se escriben juntos.
class SharedPreferencesLanguageCache implements LanguageCache {
  SharedPreferencesLanguageCache._(this._preferences, this._key);

  /// La clave de la cocina (/gestione/), la de siempre. La entrada de la
  /// clienta (/app/) usa la suya (AppEntry.languageKey): comparten origen.
  static const String key = 'radici.ui_language';

  final SharedPreferencesWithCache _preferences;
  final String _key;

  /// Lee lo guardado (una lectura del disco o de localStorage) bajo [key].
  static Future<SharedPreferencesLanguageCache> load({
    String key = SharedPreferencesLanguageCache.key,
  }) async => SharedPreferencesLanguageCache._(
    await SharedPreferencesWithCache.create(
      cacheOptions: SharedPreferencesWithCacheOptions(allowList: {key}),
    ),
    key,
  );

  @override
  CachedLanguage? read() {
    final Object? raw = _preferences.get(_key);
    if (raw is! String) return null;
    final separator = raw.indexOf(':');
    if (separator <= 0) return null;
    final language = AppLanguage.fromCode(raw.substring(0, separator));
    final userId = raw.substring(separator + 1);
    if (language == null || userId.isEmpty) return null;
    return (userId: userId, language: language);
  }

  @override
  Future<void> write(CachedLanguage value) async {
    try {
      await _preferences.setString(
        _key,
        '${value.language.code}:${value.userId}',
      );
    } on Object {
      // Sin caché, el próximo arranque espera al perfil.
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _preferences.remove(_key);
    } on Object {
      // Ver write.
    }
  }
}

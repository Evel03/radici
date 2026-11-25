// Opciones de Supabase Auth de cada entrada (ver app_entry.dart): dónde se
// guardan la sesión y el verificador PKCE, y qué links de Auth se aceptan.
import 'package:radici/core/app_entry.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Ruta de la entrada de la clienta: lo único que su predicado acepta como
/// vuelta de Auth (la web de /app/ y, en las apps, sus enlaces universales).
const String clientCallbackPath = '/app';

/// ¿Es [uri] la vuelta de un link de Auth de la entrada [entry]?
///
/// - La cocina web no usa links (entra con el código): nunca.
/// - La clienta (web) y la app nativa, solo en su ruta y solo con PKCE: un `code` o un error de
///   Auth, en la query. Un `access_token` (flujo implícito) o un
///   `refresh_token`, en la query o en el fragmento, nunca abre una sesión:
///   cualquiera puede armar esa URL con un token que no es de quien la abre.
bool isAuthCallbackUri(AppEntry entry, Uri uri) {
  if (entry == AppEntry.kitchen) return false;
  final path = uri.path;
  if (path != clientCallbackPath && !path.startsWith('$clientCallbackPath/')) {
    return false;
  }
  final query = uri.queryParameters;
  final fragment = _fragmentParameters(uri);
  for (final key in const ['access_token', 'refresh_token']) {
    if (query.containsKey(key) || fragment.containsKey(key)) return false;
  }
  return query.containsKey('code') ||
      query.containsKey('error') ||
      query.containsKey('error_code') ||
      query.containsKey('error_description') ||
      fragment.containsKey('error') ||
      fragment.containsKey('error_code') ||
      fragment.containsKey('error_description');
}

Map<String, String> _fragmentParameters(Uri uri) {
  try {
    return Uri.splitQueryString(uri.fragment);
  } on Object {
    // El fragmento de la web es una ruta (`#/accedi`), no parámetros.
    return const {};
  }
}

/// Antepone [prefix] a las claves de [inner]. gotrue 2.27.3 guarda el
/// verificador PKCE con una clave fija (`supabase.auth.token-code-verifier`):
/// sin prefijo, dos entradas del mismo origen se lo pisarían.
class PrefixedGotrueAsyncStorage extends GotrueAsyncStorage {
  const PrefixedGotrueAsyncStorage(this.prefix, this.inner);

  final String prefix;
  final GotrueAsyncStorage inner;

  @override
  Future<String?> getItem({required String key}) =>
      inner.getItem(key: '$prefix$key');

  @override
  Future<void> setItem({required String key, required String value}) =>
      inner.setItem(key: '$prefix$key', value: value);

  @override
  Future<void> removeItem({required String key}) =>
      inner.removeItem(key: '$prefix$key');
}

/// Las opciones de Auth de [entry]. PKCE en las dos.
///
/// - Cocina: la sesión y el verificador con las claves de siempre, y sin
///   detectar sesión en la URL (su login es el código del email).
/// - Clienta (web): claves propias, y solo detecta la vuelta de sus links
///   ([isAuthCallbackUri]).
/// - App nativa (`auto`): las claves de siempre (la sesión que ya hay en el
///   teléfono sigue) y el mismo predicado restringido de la clienta.
///
/// [pkceStorage] es el almacenamiento real del verificador (en los tests, uno
/// en memoria); por defecto, el de supabase_flutter.
FlutterAuthClientOptions buildAuthOptions(
  AppEntry entry,
  String supabaseUrl, {
  GotrueAsyncStorage? pkceStorage,
}) {
  final isClient = entry == AppEntry.client;
  final detects = entry != AppEntry.kitchen;
  return FlutterAuthClientOptions(
    authFlowType: AuthFlowType.pkce,
    localStorage: SharedPreferencesLocalStorage(
      persistSessionKey: entry.persistSessionKey(supabaseUrl),
    ),
    // La cocina deja el de supabase_flutter (misma clave de siempre).
    pkceAsyncStorage: isClient
        ? PrefixedGotrueAsyncStorage(
            entry.pkceKeyPrefix,
            pkceStorage ?? SharedPreferencesGotrueAsyncStorage(),
          )
        : pkceStorage,
    detectSessionInUri: detects,
    detectSessionInUriPredicate: detects
        ? (uri) => isAuthCallbackUri(entry, uri)
        : null,
  );
}

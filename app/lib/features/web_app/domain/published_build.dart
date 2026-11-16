// build.json: el id del build publicado junto a la app (/gestione/build.json).
// deploy-web.yml lo escribe con el mismo id que compila con
// `--dart-define=BUILD_ID=` (core/build_id.dart). Dart puro.
import 'dart:convert';

/// Archivo que deploy-web.yml publica junto a la app.
const String publishedBuildFile = 'build.json';

/// Clave del id en build.json: `{"buildId":"<sha corto>"}`.
const String publishedBuildIdKey = 'buildId';

/// Un id: letras, números, punto, guion y guion bajo, hasta 64. El de
/// deploy-web.yml son los 7 primeros caracteres del commit.
final RegExp _buildIdPattern = RegExp(r'^[0-9A-Za-z._-]{1,64}$');

/// build.json mide unas decenas de bytes: algo mucho más grande es otra cosa.
const int _maxBodyLength = 1024;

/// URL de build.json resuelta contra la base de la página ([pageBase], la de
/// `<base href="/gestione/">`), con `?t=<ms>`: ninguna caché en el camino
/// puede tener guardada esa URL.
Uri publishedBuildUri(Uri pageBase, DateTime now) => pageBase
    .resolve(publishedBuildFile)
    .replace(queryParameters: {'t': '${now.millisecondsSinceEpoch}'});

/// El id de build.json, o null si la respuesta es rara: no es JSON, no es un
/// objeto, no trae el id o el id no parece uno (la página de 404, por
/// ejemplo).
String? parsePublishedBuildId(String body) {
  if (body.length > _maxBodyLength) return null;
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (json is! Map<String, dynamic>) return null;
  final id = json[publishedBuildIdKey];
  return id is String && _buildIdPattern.hasMatch(id) ? id : null;
}

/// Hay una versión nueva: el id publicado es otro que el compilado. Sin id
/// compilado (flutter run, tests, iOS y Android) nunca.
bool hasNewBuild({required String compiled, required String published}) =>
    compiled.isNotEmpty && published != compiled;

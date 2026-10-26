// Idiomas de la interfaz. Los códigos son los de `profiles.locale` (it, es,
// en): con sesión, la interfaz sigue al perfil; sin sesión, al dispositivo.
import 'dart:ui' show Locale;

enum AppLanguage {
  it,
  es,
  en;

  /// Código de `profiles.locale`.
  String get code => name;

  Locale get locale => Locale(code);

  /// El idioma de [code] ("es", "it", "en"), o null si no es uno de estos.
  static AppLanguage? fromCode(Object? code) =>
      code is String ? values.asNameMap()[code] : null;
}

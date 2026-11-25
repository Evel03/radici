// Las dos entradas de la misma app: /gestione/ (la cocina: Evelyn y sus
// colaboradores, con el código del email) y /app/ (las clientas). En iOS y
// Android la app nativa es siempre la de la clienta: la cocina sigue entrando
// por /gestione/ (web o PWA).
//
// En la web la entrada la fija el build con `<meta name="radici-entry"
// content="app|gestione">` de index.html. Sin la marca (o con un valor que no
// se conoce) es la de la cocina: así /gestione/ sigue igual que antes.
//
// Las dos entradas comparten el origen (radicicucina.app), así que comparten
// localStorage: cada una guarda su sesión, el verificador PKCE y el idioma con
// claves propias, para no pisarse. Las claves de la cocina son las de siempre
// (Evelyn no sale de su sesión al actualizar).
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Nombre del `<meta>` de index.html que fija la entrada.
const String entryMetaName = 'radici-entry';

enum AppEntry {
  /// /gestione/: la cocinera y sus colaboradores.
  kitchen,

  /// /app/ y las apps de iOS y Android: las clientas.
  client;

  /// El valor del `<meta>` (`gestione` o `app`).
  String get metaValue => switch (this) {
    AppEntry.kitchen => 'gestione',
    AppEntry.client => 'app',
  };

  /// Prefijo de las claves del verificador PKCE (vacío en la cocina: la
  /// clave fija de gotrue, `supabase.auth.token-code-verifier`).
  String get pkceKeyPrefix => switch (this) {
    AppEntry.kitchen => '',
    AppEntry.client => 'radici.app.',
  };

  /// Clave de la sesión guardada (supabase_flutter) para el proyecto de
  /// [supabaseUrl]. La de la cocina es la que supabase_flutter ya usaba por
  /// defecto: `sb-<ref>-auth-token`.
  String persistSessionKey(String supabaseUrl) {
    final ref = Uri.parse(supabaseUrl).host.split('.').first;
    return switch (this) {
      AppEntry.kitchen => 'sb-$ref-auth-token',
      AppEntry.client => 'sb-$ref-app-auth-token',
    };
  }

  /// Clave de la caché del idioma (ver LanguageCache).
  String get languageKey => switch (this) {
    AppEntry.kitchen => 'radici.ui_language',
    AppEntry.client => 'radici.app.ui_language',
  };
}

/// La entrada de este arranque. Nativo: siempre la clienta. Web: la del
/// `<meta>` ([metaContent]); sin él, o con un valor desconocido, la cocina.
AppEntry resolveAppEntry({required bool isWeb, String? metaContent}) {
  if (!isWeb) return AppEntry.client;
  return metaContent?.trim() == AppEntry.client.metaValue
      ? AppEntry.client
      : AppEntry.kitchen;
}

/// La entrada de la app en marcha. `main.dart` la sobreescribe con la
/// resuelta; por defecto (y en los tests) es la de la cocina.
final appEntryProvider = Provider<AppEntry>((ref) => AppEntry.kitchen);

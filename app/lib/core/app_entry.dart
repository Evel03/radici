// Las entradas de la misma app: /gestione/ (la cocina: Evelyn y sus
// colaboradores, con el código del email) y /app/ (las clientas), estrictas
// cada una con su rol. En iOS y Android la app es una sola para los dos roles
// (`auto`, decisión del 25/11/2026: «que sirva para las dos, según la
// cuenta»): después del login, la cocina ve su área y la clienta, la suya.
//
// En la web la entrada la fija el build con `<meta name="radici-entry"
// content="app|gestione">` de index.html. Sin la marca (o con un valor que no
// se conoce) es la de la cocina: así /gestione/ sigue igual que antes.
//
// Las dos entradas web comparten el origen (radicicucina.app), así que
// comparten localStorage: la de la clienta guarda su sesión, el verificador
// PKCE y el idioma con claves propias, para no pisarse con /gestione/. Las
// claves de la cocina son las de siempre, y la app nativa (`auto`) usa esas
// mismas: la sesión que ya tiene Evelyn en TestFlight sobrevive a la
// actualización.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';

/// Nombre del `<meta>` de index.html que fija la entrada.
const String entryMetaName = 'radici-entry';

enum AppEntry {
  /// /gestione/: la cocinera y sus colaboradores.
  kitchen,

  /// /app/: las clientas (web).
  client,

  /// Las apps de iOS y Android: las dos cuentas, según el rol de la cuenta.
  auto;

  /// El valor del `<meta>` (`gestione` o `app`).
  String get metaValue => switch (this) {
    AppEntry.kitchen => 'gestione',
    AppEntry.client => 'app',
    AppEntry.auto => '',
  };

  /// Prefijo de las claves del verificador PKCE (vacío en la cocina y en la
  /// app nativa: la clave fija de gotrue, `supabase.auth.token-code-verifier`).
  String get pkceKeyPrefix => switch (this) {
    AppEntry.kitchen || AppEntry.auto => '',
    AppEntry.client => 'radici.app.',
  };

  /// Clave de la sesión guardada (supabase_flutter) para el proyecto de
  /// [supabaseUrl]. La de la cocina y la de la app nativa son las que
  /// supabase_flutter ya usaba por defecto: `sb-<ref>-auth-token`.
  String persistSessionKey(String supabaseUrl) {
    final ref = Uri.parse(supabaseUrl).host.split('.').first;
    return switch (this) {
      AppEntry.kitchen || AppEntry.auto => 'sb-$ref-auth-token',
      AppEntry.client => 'sb-$ref-app-auth-token',
    };
  }

  /// Clave de la caché del idioma (ver LanguageCache).
  String get languageKey => switch (this) {
    AppEntry.kitchen || AppEntry.auto => 'radici.ui_language',
    AppEntry.client => 'radici.app.ui_language',
  };
}

/// La entrada de este arranque. Nativo: `auto`, las dos cuentas. Web: la del
/// `<meta>` ([metaContent]); sin él, o con un valor desconocido, la cocina.
AppEntry resolveAppEntry({required bool isWeb, String? metaContent}) {
  if (!isWeb) return AppEntry.auto;
  return metaContent?.trim() == AppEntry.client.metaValue
      ? AppEntry.client
      : AppEntry.kitchen;
}

/// La entrada de la app en marcha. `main.dart` la sobreescribe con la
/// resuelta; por defecto (y en los tests) es la de la cocina.
final appEntryProvider = Provider<AppEntry>((ref) => AppEntry.kitchen);

/// ¿Se montan los avisos y providers de la cocina (pedidos nuevos)? En
/// /gestione/ siempre; en la app nativa solo con una cuenta de la cocina: al
/// salir y entrar con otra cuenta se sueltan (los providers de la cocina
/// vuelven a vacío porque dependen de la cocina de la sesión). En /app/,
/// nunca.
final kitchenAlertsEnabledProvider = Provider<bool>(
  (ref) => switch (ref.watch(appEntryProvider)) {
    AppEntry.kitchen => true,
    AppEntry.client => false,
    AppEntry.auto => ref.watch(sessionControllerProvider) is ChefSession,
  },
);

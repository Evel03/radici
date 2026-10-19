// Configuración por entorno. Se inyecta al compilar con
// `--dart-define-from-file=env/dev.json` (ver app/README.md).
// Solo contiene valores públicos: la clave de Supabase es la publicable
// (protegida por RLS). Nunca poner acá claves secretas ni de servicio.
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppEnvironment { dev, prod }

class AppEnv {
  const AppEnv({
    required this.environment,
    this.supabaseUrl = '',
    this.supabasePublishableKey = '',
  });

  /// Lee los valores definidos al compilar. Sin defines: `dev` sin backend.
  factory AppEnv.fromDefines() => AppEnv.parse(
    appEnv: const String.fromEnvironment('APP_ENV', defaultValue: 'dev'),
    supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
    supabasePublishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );

  /// Valida y normaliza. Un `APP_ENV` desconocido es un error de
  /// configuración: mejor fallar al arrancar que correr con el entorno mal.
  factory AppEnv.parse({
    required String appEnv,
    required String supabaseUrl,
    required String supabasePublishableKey,
  }) {
    final environment = AppEnvironment.values.asNameMap()[appEnv.trim()];
    if (environment == null) {
      throw ArgumentError.value(appEnv, 'APP_ENV', 'Tiene que ser dev o prod');
    }
    return AppEnv(
      environment: environment,
      supabaseUrl: supabaseUrl.trim(),
      supabasePublishableKey: supabasePublishableKey.trim(),
    );
  }

  final AppEnvironment environment;
  final String supabaseUrl;

  /// Clave publicable de Supabase (sb_publishable_...).
  final String supabasePublishableKey;

  bool get isDev => environment == AppEnvironment.dev;

  /// Hay backend solo si están la URL y la clave.
  bool get hasSupabase => supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;

  /// En dev sin backend se muestra un aviso discreto; en prod nunca.
  bool get showBackendNotice => isDev && !hasSupabase;
}

/// Entorno de la app. `main.dart` lo sobreescribe con el valor ya leído;
/// los tests lo sobreescriben con el que necesiten.
final appEnvProvider = Provider<AppEnv>((ref) => AppEnv.fromDefines());

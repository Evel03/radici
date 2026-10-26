// Arranque: entorno, Supabase (si está configurado), idioma guardado,
// licencias y ProviderScope.
// Correr con: flutter run --dart-define-from-file=env/dev.json
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/app.dart';
import 'package:radici/core/env.dart';
import 'package:radici/features/settings/data/language_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Roboto va empaquetada (pubspec.yaml): su licencia Apache 2.0 se muestra
  // en la pantalla de licencias.
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/fonts/LICENSE-Roboto.txt');
    yield LicenseEntryWithLineBreaks(const ['Roboto'], license);
  });

  final env = AppEnv.fromDefines();

  // Sin URL o sin clave la app arranca igual, sin backend (en dev se avisa).
  // supabase_flutter recupera la sesión guardada antes de seguir.
  if (env.hasSupabase) {
    await Supabase.initialize(
      url: env.supabaseUrl,
      publishableKey: env.supabasePublishableKey,
    );
  }

  runApp(
    ProviderScope(
      overrides: [
        appEnvProvider.overrideWithValue(env),
        languageCacheProvider.overrideWithValue(await _loadLanguageCache()),
      ],
      child: const RadiciApp(),
    ),
  );
}

/// Idioma guardado de quien tiene la sesión: se lee antes del primer cuadro
/// para que la app arranque ya en ese idioma. Si el almacenamiento falla, la
/// app sigue con la caché en memoria (el idioma llega con el perfil).
Future<LanguageCache> _loadLanguageCache() async {
  try {
    return await SharedPreferencesLanguageCache.load();
  } on Object {
    return MemoryLanguageCache();
  }
}

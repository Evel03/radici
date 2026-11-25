// Arranque: entorno, Supabase (si está configurado), idioma guardado,
// licencias y ProviderScope.
// Correr con: flutter run --dart-define-from-file=env/dev.json
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/app.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/auth_options.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/env.dart';
import 'package:radici/features/settings/data/language_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Las fuentes van empaquetadas (pubspec.yaml): sus licencias (Apache 2.0 y
  // OFL) se muestran en la pantalla de licencias.
  LicenseRegistry.addLicense(() async* {
    for (final (family, file) in const [
      ('Roboto', 'LICENSE-Roboto.txt'),
      ('Cinzel', 'LICENSE-Cinzel.txt'),
      ('Cormorant Garamond', 'LICENSE-CormorantGaramond.txt'),
    ]) {
      final license = await rootBundle.loadString('assets/fonts/$file');
      yield LicenseEntryWithLineBreaks([family], license);
    }
  });

  final env = AppEnv.fromDefines();
  // La entrada fija dónde se guardan la sesión y el idioma: se resuelve antes
  // de inicializar Supabase (ver app_entry.dart).
  final entry = resolveAppEntry(
    isWeb: kIsWeb,
    metaContent: createPlatformBrowser().readMeta(entryMetaName),
  );

  // Sin URL o sin clave la app arranca igual, sin backend (en dev se avisa).
  // supabase_flutter recupera la sesión guardada antes de seguir.
  if (env.hasSupabase) {
    await Supabase.initialize(
      url: env.supabaseUrl,
      publishableKey: env.supabasePublishableKey,
      authOptions: buildAuthOptions(entry, env.supabaseUrl),
    );
  }

  runApp(
    ProviderScope(
      overrides: [
        appEnvProvider.overrideWithValue(env),
        appEntryProvider.overrideWithValue(entry),
        languageCacheProvider.overrideWithValue(
          await _loadLanguageCache(entry),
        ),
      ],
      child: const RadiciApp(),
    ),
  );
}

/// Idioma guardado de quien tiene la sesión: se lee antes del primer cuadro
/// para que la app arranque ya en ese idioma. Si el almacenamiento falla, la
/// app sigue con la caché en memoria (el idioma llega con el perfil).
Future<LanguageCache> _loadLanguageCache(AppEntry entry) async {
  try {
    return await SharedPreferencesLanguageCache.load(key: entry.languageKey);
  } on Object {
    return MemoryLanguageCache();
  }
}

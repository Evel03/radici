// Arranque: entorno, Supabase (si está configurado), licencias y ProviderScope.
// Correr con: flutter run --dart-define-from-file=env/dev.json
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mestolo/app.dart';
import 'package:mestolo/core/env.dart';
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
      overrides: [appEnvProvider.overrideWithValue(env)],
      child: const MestoloApp(),
    ),
  );
}

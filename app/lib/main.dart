// Arranque: entorno, Supabase (si está configurado) y ProviderScope.
// Correr con: flutter run --dart-define-from-file=env/dev.json
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mestolo/app.dart';
import 'package:mestolo/core/env.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final env = AppEnv.fromDefines();

  // Sin URL o sin clave la app arranca igual, sin backend (en dev se avisa).
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

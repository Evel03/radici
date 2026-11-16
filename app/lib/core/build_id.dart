// Id del build de la web (/gestione/). deploy-web.yml compila con
// `--dart-define=BUILD_ID=<sha corto>` y publica el mismo id en
// /gestione/build.json: la app los compara para avisar que hay una versión
// nueva (features/web_app) y lo muestra en Impostazioni. Vacío en flutter run,
// en los tests y en las apps de iOS y Android: sin aviso ni versión.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Nombre del `--dart-define` (el mismo de deploy-web.yml).
const String buildIdDefine = 'BUILD_ID';

/// El id con que se compiló la app, o vacío.
final buildIdProvider = Provider<String>(
  (ref) => const String.fromEnvironment(buildIdDefine).trim(),
);

// Aviso de versión nueva de /gestione/. Evelyn deja la app abierta en el
// iPhone días enteros: sin esto seguiría con la versión que cargó, aunque haya
// un deploy nuevo. Se compara el id compilado (core/build_id.dart) con el de
// build.json al abrir y al volver a primer plano (presentation/
// web_app_notices.dart), como mucho una vez cada [updateCheckInterval]. Nunca
// recarga sola: lo hace «Aggiorna», con [AppUpdateController.reload].
//
// Sin red, con una respuesta rara o sin id compilado (flutter run, tests, iOS
// y Android) no avisa nada.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/features/web_app/data/published_build_repository.dart';
import 'package:radici/features/web_app/domain/published_build.dart';

/// Como mucho una lectura de build.json cada 5 minutos (también si la
/// anterior falló).
const Duration updateCheckInterval = Duration(minutes: 5);

/// Una lectura que no responde en este tiempo se da por perdida: la próxima
/// vuelta a primer plano (pasado [updateCheckInterval]) vuelve a mirar.
const Duration updateCheckTimeout = Duration(seconds: 15);

/// true: hay una versión nueva publicada.
final appUpdateControllerProvider =
    NotifierProvider<AppUpdateController, bool>(AppUpdateController.new);

class AppUpdateController extends Notifier<bool> {
  DateTime? _lastCheck;
  bool _checking = false;

  @override
  bool build() => false;

  /// Lee build.json y compara, salvo que haya una lectura en curso o la
  /// última haya empezado hace menos de [updateCheckInterval]. Nunca lanza.
  Future<void> check() async {
    final compiled = ref.read(buildIdProvider);
    if (compiled.isEmpty || _checking) return;
    final now = ref.read(clockProvider)();
    final last = _lastCheck;
    // Si el reloj del teléfono vuelve atrás, se mira igual.
    if (last != null &&
        !now.isBefore(last) &&
        now.difference(last) < updateCheckInterval) {
      return;
    }
    _lastCheck = now;
    _checking = true;
    String? published;
    try {
      published = await ref
          .read(publishedBuildRepositoryProvider)
          .fetchPublishedBuildId()
          .timeout(updateCheckTimeout, onTimeout: () => null);
    } on Object {
      published = null;
    } finally {
      _checking = false;
    }
    // Sin respuesta queda lo que había: un aviso ya dado no se va por un
    // intento sin red.
    if (!ref.mounted || published == null) return;
    state = hasNewBuild(compiled: compiled, published: published);
  }

  /// «Aggiorna»: recarga la página, que trae la versión nueva (/gestione/ se
  /// sirve con `Cache-Control: no-cache`).
  void reload() => ref.read(browserProvider).reload();
}

// Aviso de Safari (domain/install_hint.dart): se muestra en el iPhone o el
// iPad fuera de la app instalada hasta que Evelyn lo cierra, y cerrado no
// vuelve en ese dispositivo (marca en localStorage). Fuera de la web nunca.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/features/web_app/domain/install_hint.dart';

/// true: se muestra el aviso de Safari.
final installHintControllerProvider =
    NotifierProvider<InstallHintController, bool>(InstallHintController.new);

class InstallHintController extends Notifier<bool> {
  @override
  bool build() {
    final browser = ref.watch(browserProvider);
    final info = browser.info;
    if (info == null || !isIosBrowserOutsideApp(info)) return false;
    return browser.readFlag(installHintDismissedKey) == null;
  }

  /// «Chiudi». Si el dispositivo no deja guardar la marca, el aviso vuelve la
  /// próxima vez que se abra.
  void dismiss() {
    ref.read(browserProvider).writeFlag(installHintDismissedKey, '1');
    state = false;
  }
}

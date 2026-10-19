// Abre links externos (wa.me, tel:, mailto:). Detrás de una interfaz para
// que los tests verifiquen qué se abre sin depender del plugin.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

abstract interface class LinkLauncher {
  /// Abre [uri] en la app que corresponda. Devuelve false si no se pudo.
  ///
  /// En la web hay que llamarlo directo desde el gesto del usuario (sin
  /// esperar otra cosa antes): si no, el navegador bloquea la ventana nueva.
  Future<bool> launch(Uri uri);
}

final linkLauncherProvider = Provider<LinkLauncher>(
  (ref) => const UrlLauncherLinkLauncher(),
);

class UrlLauncherLinkLauncher implements LinkLauncher {
  const UrlLauncherLinkLauncher();

  @override
  Future<bool> launch(Uri uri) async {
    try {
      // WhatsApp y el teléfono son apps externas: nunca una vista web interna.
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // PlatformException si no hay ninguna app que lo abra (p. ej. un
      // emulador sin teléfono).
      return false;
    }
  }
}

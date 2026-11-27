// Abre links externos (wa.me, tel:, mailto:) y páginas de la web pública.
// Detrás de una interfaz para que los tests verifiquen qué se abre sin
// depender del plugin.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

abstract interface class LinkLauncher {
  /// Abre [uri] en la app que corresponda. Devuelve false si no se pudo.
  ///
  /// En la web hay que llamarlo directo desde el gesto del usuario (sin
  /// esperar otra cosa antes): si no, el navegador bloquea la ventana nueva.
  Future<bool> launch(Uri uri);

  /// Abre una página de la web de Radici sin salir de la app: una hoja de
  /// Safari (SFSafariViewController) en iOS y una pestaña de Chrome (Custom
  /// Tabs) en Android. Es el navegador del sistema, así que el anti-spam
  /// (Turnstile) funciona como en la web. Si no se puede, abre el navegador.
  /// Devuelve false si no se pudo abrir de ninguna forma.
  Future<bool> openPage(Uri uri);
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

  @override
  Future<bool> openPage(Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return true;
    } on Object {
      // Sin Custom Tabs ni vista de Safari (un Android sin Chrome, por
      // ejemplo): se prueba con el navegador.
    }
    return launch(uri);
  }
}

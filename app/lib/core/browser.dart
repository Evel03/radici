// Lo que la app usa del navegador cuando corre como web (/gestione/): leer un
// archivo sin caché, recargar la página, qué navegador es y una marca guardada
// en el dispositivo. Fuera de la web (iOS, Android y los tests en la VM) no
// hace nada: el import condicional elige browser_stub.dart y package:web nunca
// se compila ahí.
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/browser_stub.dart'
    if (dart.library.js_interop) 'package:radici/core/browser_web.dart';

/// Lo que el navegador dice de sí mismo (para el aviso de Safari).
@immutable
class BrowserInfo {
  const BrowserInfo({
    required this.userAgent,
    required this.platform,
    required this.maxTouchPoints,
    required this.navigatorStandalone,
    required this.displayModeStandalone,
  });

  /// `navigator.userAgent`.
  final String userAgent;

  /// `navigator.platform` ("iPhone", "MacIntel"…).
  final String platform;

  /// `navigator.maxTouchPoints`: el iPad se presenta como Mac, pero táctil.
  final int maxTouchPoints;

  /// `navigator.standalone`: solo Safari de iOS lo tiene, y es true en la app
  /// agregada a la pantalla de inicio.
  final bool navigatorStandalone;

  /// `matchMedia('(display-mode: standalone)')`: abierta como app instalada.
  final bool displayModeStandalone;
}

abstract interface class Browser {
  /// La base de la página (`document.baseURI`: con `<base href="/gestione/">`
  /// es https://…/gestione/ aunque la ruta vaya en el fragmento). null fuera
  /// de la web.
  Uri? get baseUri;

  /// GET de [uri] sin la caché del navegador (`cache: 'no-store'`). El cuerpo
  /// si respondió 200; null si no (sin red, otro estado) y fuera de la web.
  /// Nunca lanza.
  Future<String?> fetchFresh(Uri uri);

  /// Recarga la página. Fuera de la web no hace nada.
  void reload();

  /// null fuera de la web.
  BrowserInfo? get info;

  /// Una marca guardada en este dispositivo (localStorage), o null. Nunca
  /// lanza.
  String? readFlag(String key);

  /// Guarda una marca en este dispositivo. Nunca lanza: si el almacenamiento
  /// falla (Safari privado, datos del sitio borrados), no queda guardada.
  void writeFlag(String key, String value);
}

/// El navegador real en la web; fuera de la web, uno que no hace nada.
final browserProvider = Provider<Browser>((ref) => createBrowser());

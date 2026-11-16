// Aviso de Safari: Evelyn usa /gestione/ desde el ícono de la pantalla de
// inicio, pero el botón del email abre el navegador, que tiene otra sesión (y
// le pide el código otra vez). En el iPhone o el iPad, fuera de la app
// instalada, una tarjeta le recuerda abrir Radici desde el ícono. Dart puro.
import 'package:radici/core/browser.dart';

/// Marca en localStorage: el aviso ya se cerró en este dispositivo.
const String installHintDismissedKey = 'radici.install_hint_dismissed';

final RegExp _iosDevice = RegExp(r'\b(iPhone|iPad|iPod)\b');

/// iPhone o iPad en el navegador, fuera de la app agregada a la pantalla de
/// inicio. En iOS todos los navegadores son Safari por dentro (WebKit) y
/// tampoco comparten la sesión con la app instalada: cuentan todos.
bool isIosBrowserOutsideApp(BrowserInfo info) {
  if (info.navigatorStandalone || info.displayModeStandalone) return false;
  return _iosDevice.hasMatch(info.userAgent) ||
      // El iPad (desde iPadOS 13) se presenta como un Mac, pero táctil.
      (info.platform == 'MacIntel' && info.maxTouchPoints > 1);
}

// Qué puede cargar la WebView del captcha (versión nativa): solo la página
// /captcha/ de la web y, dentro de ella, los marcos de Cloudflare Turnstile.
// Todo lo demás (un link, una redirección, otro sitio) se bloquea: la WebView
// lleva un canal hacia la app y no tiene que poder navegar a otro lado.
import 'package:radici/core/captcha/captcha_protocol.dart';

const String _turnstileHost = 'challenges.cloudflare.com';

/// [url] es una navegación que la WebView deja pasar. En el marco principal,
/// solo la página del captcha (misma ruta exacta, sobre https y el puerto 443,
/// sin usuario; la query cambia con el idioma); en un marco interno, solo
/// Turnstile (https) y los documentos en blanco que él mismo crea.
bool isCaptchaNavigationAllowed(String url, {required bool isMainFrame}) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } on FormatException {
    return false;
  }
  if (!isMainFrame && (url == 'about:blank' || url == 'about:srcdoc')) return true;
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.port != 443) return false;
  if (isMainFrame) {
    final page = Uri.parse(captchaProductionOrigin);
    return uri.host == page.host && uri.path == captchaPagePath;
  }
  return uri.host == _turnstileHost;
}

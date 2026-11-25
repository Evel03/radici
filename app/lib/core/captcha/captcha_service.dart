// Token de captcha de Auth para los pedidos que lo necesitan (hoy, pedir el
// código de acceso; después, registro, contraseña y recuperación).
//
// Cómo se obtiene: la página https://radicicucina.app/captcha/ dibuja el
// Turnstile de Auth y devuelve el token por mensajes (docs/contracts/auth.md
// §10). En la web (/gestione/, más adelante /app/) va en un iframe del mismo
// sitio; en iOS y Android, en una WebView fijada a esa página
// (captcha_navigation.dart). Cada llamada abre la página de nuevo y pide un
// token con un id nuevo: un token de Turnstile sirve una sola vez (~300 s) y
// nunca queda uno suelto en la app.
//
// FAIL-OPEN HASTA PR11 (decisión del 25/11/2026): Auth todavía no exige captcha
// y el login de Evelyn no puede depender de una página de un tercero. Mientras
// [captchaRequired] sea false, si no hay token (tiempo, sin red, Cloudflare
// bloqueado) el pedido sale igual, sin token. PR11 prende el captcha en Auth y
// pone [captchaRequired] en true en el mismo cambio: entonces la falta de
// token es un error que la persona puede reintentar (AuthFailureKind.captcha).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/captcha/captcha_broker.dart';
import 'package:radici/core/captcha/captcha_platform_native.dart'
    if (dart.library.js_interop) 'package:radici/core/captcha/captcha_platform_web.dart';

/// PR11: cambiar a true cuando Auth exija captcha (security_captcha_enabled).
/// Con false, un token que no llega nunca impide el login (ver arriba).
const bool captchaRequired = false;

/// Los tests la sobreescriben para probar los dos modos.
final captchaRequiredProvider = Provider<bool>((ref) => captchaRequired);

abstract interface class CaptchaService {
  /// Un token nuevo (de un solo uso), o null si no se pudo obtener a tiempo.
  /// Nunca lanza. [locale] (it, es, en): el idioma de lo que la página muestre
  /// si Cloudflare pide tocar la casilla.
  Future<String?> token({String? locale});
}

final captchaServiceProvider = Provider<CaptchaService>(
  (ref) => CaptchaBroker(sessionFactory: createCaptchaSessionFactory(ref)),
);

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
// OBLIGATORIO EN PRODUCCIÓN (PR11, 26/11/2026): Auth de producción exige el
// captcha (docs/contracts/auth.md §10). Con APP_ENV=prod (la web, iOS y
// Android publicados) la falta de token es un error que la persona puede
// reintentar (AuthFailureKind.captcha) y nada sale sin token. Con APP_ENV=dev
// sigue fail-open: el Supabase local no exige captcha y, en local, la página
// /captcha/ no está en el origen de la app, así que el pedido sale sin token.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/captcha/captcha_broker.dart';
import 'package:radici/core/captcha/captcha_platform_native.dart'
    if (dart.library.js_interop) 'package:radici/core/captcha/captcha_platform_web.dart';
import 'package:radici/core/env.dart';

/// ¿El captcha es obligatorio? Sí en producción (Auth lo exige desde PR11);
/// en desarrollo no (ver arriba). Los tests la sobreescriben o cambian el
/// entorno.
final captchaRequiredProvider = Provider<bool>(
  (ref) => captchaRequiredIn(ref.watch(appEnvProvider)),
);

/// La regla de [captchaRequiredProvider], aparte para los tests.
bool captchaRequiredIn(AppEnv env) => !env.isDev;

abstract interface class CaptchaService {
  /// Un token nuevo (de un solo uso), o null si no se pudo obtener a tiempo.
  /// Nunca lanza. [locale] (it, es, en): el idioma de lo que la página muestre
  /// si Cloudflare pide tocar la casilla.
  Future<String?> token({String? locale});

  /// Por qué el último [token] dio null, en un código corto y seguro para
  /// mostrar (captcha_broker.dart); null si dio token. Diagnóstico: nunca lleva
  /// el token ni datos de la persona.
  String? get lastFailure;
}

final captchaServiceProvider = Provider<CaptchaService>(
  (ref) => CaptchaBroker(sessionFactory: createCaptchaSessionFactory(ref)),
);

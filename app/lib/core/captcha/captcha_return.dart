// El captcha de Auth en iOS y Android (desde el 26/11/2026): la página
// /captcha/ en el navegador real del sistema, no en una WebView. Turnstile no
// acepta la WebView de la app (error 600010, «challenge execution failure»:
// Cloudflare no le cree aunque se toque la casilla) y en Safari sí anda.
//
// Cómo: [authenticate] abre https://radicicucina.app/captcha/?channel=return&id=<id>
// en una hoja del Safari real (ASWebAuthenticationSession, sin el aviso de
// «quiere iniciar sesión» porque la sesión es efímera) o en una pestaña de
// Chrome (Auth Tab / Custom Tab) y espera la vuelta a radicicaptcha://result.
// La página pide el token sola, con ese id, y vuelve con el token o con el
// código del error (web/src/captcha/protocol.ts, canal «return»). Lógica pura:
// la plataforma pone [authenticate] (captcha_platform_native.dart).
// Nunca lanza: sin token devuelve null y deja el motivo en [lastFailure]. El
// token es de un solo uso y nunca se loguea.
import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:radici/core/captcha/captcha_protocol.dart';
import 'package:radici/core/captcha/captcha_service.dart';

/// Abre [url] en el navegador del sistema y devuelve la dirección con la que
/// volvió (radicicaptcha://…). Lanza PlatformException si la persona cerró la
/// hoja (código «CANCELED») o si el sistema no pudo abrirla.
typedef ReturnAuthenticate = Future<String> Function(String url);

class ReturnCaptchaService implements CaptchaService {
  ReturnCaptchaService({required this.authenticate, String Function()? newId})
    : _newId = newId ?? newCaptchaId;

  final ReturnAuthenticate authenticate;
  final String Function() _newId;

  /// Un pedido a la vez: cada uno abre su propia hoja.
  Future<void> _tail = Future<void>.value();

  @override
  String? lastFailure;

  @override
  Future<String?> token({String? locale}) {
    final result = _tail.then((_) => _run(locale));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String?> _run(String? locale) async {
    final id = _newId();
    final url = captchaPageUri(captchaProductionOrigin, locale: locale, returnId: id).toString();
    final String returned;
    try {
      returned = await authenticate(url);
    } on PlatformException catch (error) {
      // CANCELED: la persona cerró la hoja (o volvió a la app sin terminar).
      lastFailure = error.code == 'CANCELED' ? 'app-cancelled' : 'app-browser-${safeCaptchaCode(error.code)}';
      return null;
    } on Object {
      lastFailure = 'app-unavailable';
      return null;
    }
    switch (parseCaptchaReturn(returned, id)) {
      case CaptchaToken(:final token):
        lastFailure = null;
        return token;
      case CaptchaError(:final code):
        lastFailure = 'page-$code';
        return null;
      default:
        lastFailure = 'app-bad-return';
        return null;
    }
  }
}

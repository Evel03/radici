// El captcha en la web (/gestione/, más adelante /app/): un iframe del mismo
// sitio con /captcha/ y mensajes con postMessage. Solo se compila para la web:
// lo elige el import condicional de captcha_service.dart.
//
// Verificaciones en los dos sentidos (la página hace las suyas, web/src/captcha/
// protocol.ts):
// - lo que llega se acepta solo si event.origin es EXACTAMENTE el origen de la
//   página (el de la app: mismo sitio) y event.source es la ventana de ESTE
//   iframe; el resto se ignora;
// - lo que se manda lleva ese mismo origen como destino (nunca "*"): si el
//   iframe estuviera en otro sitio, el navegador no entrega nada.
// El iframe se crea en cada pedido y se saca del DOM al terminar. Mide 1 px y
// no se ve; si Cloudflare pide tocar la casilla, se muestra al centro con un
// fondo atenuado (el botón «Annulla» es de la página, con su idioma).
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/captcha/captcha_broker.dart';
import 'package:radici/core/captcha/captcha_protocol.dart';
import 'package:radici/core/captcha/captcha_service.dart';
import 'package:web/web.dart' as web;

/// En la web: el iframe de /captcha/ del mismo sitio, con CaptchaBroker.
CaptchaService createCaptchaService(Ref ref) => CaptchaBroker(sessionFactory: createCaptchaSessionFactory(ref));

CaptchaSessionFactory createCaptchaSessionFactory(Ref ref) =>
    (locale) => WebCaptchaSession(origin: web.window.location.origin, locale: locale);

/// Estilo del marco sin que se vea (1 px: Turnstile resuelve solo).
const String _hiddenStyle =
    'position:fixed;left:0;bottom:0;width:1px;height:1px;border:0;opacity:0.01;pointer-events:none;z-index:2147483647;';

/// Estilo del marco cuando la persona tiene que tocar la casilla.
const String _visibleStyle =
    'position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);width:min(340px,92vw);height:260px;border:0;'
    'border-radius:12px;background:#f5ede1;z-index:2147483647;box-shadow:0 0 0 100vmax rgba(0,0,0,0.45);';

class WebCaptchaSession implements CaptchaSession {
  WebCaptchaSession({required String origin, String? locale}) : _origin = origin {
    final frame = web.HTMLIFrameElement()
      ..src = captchaPageUri(origin, locale: locale).toString()
      ..tabIndex = -1
      // Un marco sin contenido para los lectores de pantalla: la página solo habla con la app.
      ..setAttribute('aria-hidden', 'true')
      ..setAttribute('referrerpolicy', 'same-origin');
    frame.style.cssText = _hiddenStyle;
    _frame = frame;
    _listener = _onMessage.toJS;
    web.window.addEventListener('message', _listener);
    web.document.body?.append(frame);
  }

  final String _origin;
  late final web.HTMLIFrameElement _frame;
  late final JSFunction _listener;
  final StreamController<CaptchaReply> _replies = StreamController<CaptchaReply>.broadcast();

  @override
  Stream<CaptchaReply> get replies => _replies.stream;

  void _onMessage(web.MessageEvent event) {
    // Origen exacto y la ventana de este marco: otro sitio, otro marco u otra ventana, se ignoran.
    if (event.origin != _origin) return;
    final source = event.source;
    final window = _frame.contentWindow;
    if (source == null || window == null || !source.strictEquals(window).toDart) return;
    final reply = parseCaptchaReply(event.data.dartify());
    if (reply == null) return;
    if (reply case CaptchaInteractive(:final visible)) {
      _frame.style.cssText = visible ? _visibleStyle : _hiddenStyle;
      _frame.tabIndex = visible ? 0 : -1;
      if (visible) {
        _frame.removeAttribute('aria-hidden');
      } else {
        _frame.setAttribute('aria-hidden', 'true');
      }
    }
    _replies.add(reply);
  }

  @override
  void request(String id) {
    _frame.contentWindow?.postMessage(captchaRequestMessage(id).toJS, _origin.toJS);
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', _listener);
    _frame.remove();
    unawaited(_replies.close());
  }
}

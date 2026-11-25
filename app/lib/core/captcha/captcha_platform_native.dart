// El captcha en iOS y Android: una WebView (webview_flutter) fijada a la página
// https://radicicucina.app/captcha/?channel=native. La página manda por el
// canal JavaScript `RadiciCaptcha` y recibe el pedido de un token llamando a
// window.radiciCaptchaRequest(id). La WebView solo puede cargar esa página y
// los marcos de Turnstile (captcha_navigation.dart). Es el import por defecto
// de captcha_service.dart; en la web lo reemplaza captcha_platform_web.dart.
//
// Dónde se ve: CaptchaHost (captcha_host.dart) la dibuja encima de la app, de
// 1×1 px mientras Turnstile resuelve solo y en grande si Cloudflare pide tocar
// la casilla. Sin ese widget la WebView no llega a cargar.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/captcha/captcha_broker.dart';
import 'package:radici/core/captcha/captcha_navigation.dart';
import 'package:radici/core/captcha/captcha_protocol.dart';
import 'package:radici/core/captcha/captcha_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

CaptchaSessionFactory createCaptchaSessionFactory(Ref ref) {
  final ui = ref.read(captchaUiProvider.notifier);
  return (locale) => NativeCaptchaSession(
    page: captchaPageUri(captchaProductionOrigin, locale: locale, native: true),
    ui: ui,
  );
}

class NativeCaptchaSession implements CaptchaSession {
  NativeCaptchaSession({required Uri page, required this._ui}) {
    // Turnstile no necesita ningún permiso de la plataforma (cámara, micrófono…): se deniegan todos.
    final controller = WebViewController(onPermissionRequest: (request) => request.deny())
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              isCaptchaNavigationAllowed(request.url, isMainFrame: request.isMainFrame)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onWebResourceError: (error) {
            // Solo importa si falla la página en sí (sin red, sin certificado): sin ella no hay token.
            if (error.isForMainFrame ?? false) _replies.add(const CaptchaLoadFailed());
          },
        ),
      )
      ..addJavaScriptChannel(
        captchaNativeChannel,
        onMessageReceived: (message) {
          final reply = parseCaptchaReply(message.message);
          if (reply == null) return;
          if (reply case CaptchaInteractive(:final visible)) _ui.setInteractive(visible: visible);
          _replies.add(reply);
        },
      )
      ..loadRequest(page);
    _controller = controller;
    _ui.open(controller);
  }

  final CaptchaUi _ui;
  late final WebViewController _controller;
  final StreamController<CaptchaReply> _replies = StreamController<CaptchaReply>.broadcast();

  @override
  Stream<CaptchaReply> get replies => _replies.stream;

  @override
  void request(String id) {
    // El id va dentro de código JavaScript: solo si es un id de pedido (32 hexadecimales).
    if (!isCaptchaId(id)) throw ArgumentError.value(id, 'id');
    unawaited(_controller.runJavaScript("window.$captchaNativeRequestFunction('$id')").catchError((Object _) {}));
  }

  @override
  void dispose() {
    _ui.close(_controller);
    unawaited(_replies.close());
  }
}

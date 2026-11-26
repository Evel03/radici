// El captcha en iOS y Android: la página /captcha/ en el navegador real del
// sistema (Safari: ASWebAuthenticationSession; Android: Auth Tab o Custom Tab
// de Chrome), con flutter_web_auth_2. Turnstile no acepta la WebView de la app
// (error 600010) y en Safari sí: ver captcha_return.dart. Es el import por
// defecto de captcha_service.dart; en la web lo reemplaza captcha_platform_web.dart.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:radici/core/captcha/captcha_protocol.dart';
import 'package:radici/core/captcha/captcha_return.dart';
import 'package:radici/core/captcha/captcha_service.dart';

CaptchaService createCaptchaService(Ref ref) => ReturnCaptchaService(
  authenticate: (url) => FlutterWebAuth2.authenticate(
    url: url,
    callbackUrlScheme: captchaReturnScheme,
    // Efímera: sin las cookies de Safari ni el aviso de «quiere iniciar sesión».
    options: const FlutterWebAuth2Options(preferEphemeral: true),
  ),
);

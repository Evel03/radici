// Lo que deja pasar la WebView del captcha: la página /captcha/ en el marco
// principal y Turnstile en los marcos internos; todo lo demás, bloqueado.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/captcha/captcha_navigation.dart';
import 'package:radici/core/captcha/captcha_protocol.dart';

void main() {
  bool allowedMain(String url) => isCaptchaNavigationAllowed(url, isMainFrame: true);
  bool allowedSub(String url) => isCaptchaNavigationAllowed(url, isMainFrame: false);

  group('marco principal: solo la página del captcha', () {
    test('deja pasar la página que abre la app, con su query', () {
      expect(allowedMain('https://radicicucina.app/captcha/?channel=native&lang=it'), isTrue);
      expect(allowedMain('https://radicicucina.app/captcha/'), isTrue);
      expect(allowedMain(captchaPageUri(captchaProductionOrigin, locale: 'es', native: true).toString()), isTrue);
      // El host no distingue mayúsculas.
      expect(allowedMain('https://RadiciCucina.app/captcha/?channel=native'), isTrue);
    });

    test('bloquea cualquier otra página, host, esquema, puerto o ruta', () {
      for (final url in [
        'https://radicicucina.app/',
        'https://radicicucina.app/gestione/',
        'https://radicicucina.app/captcha', // sin la barra: es otra ruta (Pages redirige)
        'https://radicicucina.app/captcha/otra',
        'https://radicicucina.app/captcha/../gestione/',
        'https://radicicucina.app/privacy/',
        'http://radicicucina.app/captcha/',
        'https://radicicucina.app:8443/captcha/',
        'https://radicicucina.app:444/captcha/',
        'https://www.radicicucina.app/captcha/',
        'https://radicicucina.app.evil.example/captcha/',
        'https://evil.example/captcha/',
        'https://radicicucina.app@evil.example/captcha/',
        'https://user:pw@radicicucina.app/captcha/',
        'https://challenges.cloudflare.com/',
        'https://challenges.cloudflare.com/captcha/',
        'about:blank',
        'javascript:alert(1)',
        'file:///etc/passwd',
        'data:text/html,hola',
        'intent://scan/#Intent;scheme=zxing;end',
        'tel:+390000000',
        'mailto:a@b.example',
        '',
        'esto no es una url',
      ]) {
        expect(allowedMain(url), isFalse, reason: url);
      }
    });
  });

  group('marcos internos: solo Turnstile', () {
    test('deja pasar los marcos de Cloudflare y los documentos en blanco', () {
      expect(allowedSub('https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/turnstile/if/ov2/av0/rcv/0abc/0x4AAA/light/fbE/new/normal/auto/'), isTrue);
      expect(allowedSub('https://challenges.cloudflare.com/turnstile/v0/g/abc/api.js'), isTrue);
      expect(allowedSub('about:blank'), isTrue);
      expect(allowedSub('about:srcdoc'), isTrue);
    });

    test('bloquea el resto, también el propio sitio y los parecidos a Cloudflare', () {
      for (final url in [
        'https://radicicucina.app/captcha/',
        'https://radicicucina.app/gestione/',
        'http://challenges.cloudflare.com/',
        'https://challenges.cloudflare.com:8443/',
        'https://challenges.cloudflare.com.evil.example/',
        'https://evil-challenges.cloudflare.com/',
        'https://cloudflare.com/',
        'https://www.cloudflare.com/privacypolicy/',
        'https://challenges.cloudflare.com@evil.example/',
        'https://evil.example/',
        'javascript:alert(1)',
        'data:text/html,hola',
        'blob:https://challenges.cloudflare.com/abc',
        'about:blank#x',
      ]) {
        expect(allowedSub(url), isFalse, reason: url);
      }
    });

    test('about:blank solo en un marco interno: la página principal no puede quedar en blanco', () {
      expect(allowedMain('about:srcdoc'), isFalse);
    });
  });
}

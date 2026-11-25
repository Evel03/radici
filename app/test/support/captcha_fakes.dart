// Captcha de Auth simulado: los tests nunca abren la página /captcha/ (ni una
// WebView ni un iframe).
import 'package:radici/core/captcha/captcha_service.dart';

/// Sin token, como cuando la página no responde: el login sigue sin captcha
/// mientras Auth no lo exige (fail-open).
class NoCaptchaService implements CaptchaService {
  const NoCaptchaService();

  @override
  Future<String?> token({String? locale}) async => null;
}

/// Entrega un token distinto en cada llamada y anota cuántas se pidieron y en
/// qué idioma. [failWith]: si es true, cada llamada lanza (un servicio roto:
/// tampoco tiene que frenar el login).
class FakeCaptchaService implements CaptchaService {
  FakeCaptchaService({this.available = true, this.failWith = false});

  /// false: no hay token (null), como un tiempo agotado.
  bool available;
  bool failWith;

  final List<String?> locales = [];

  int get calls => locales.length;

  @override
  Future<String?> token({String? locale}) async {
    locales.add(locale);
    if (failWith) throw StateError('captcha roto');
    return available ? 'captcha-token-$calls' : null;
  }
}

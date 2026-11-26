// Captcha de Auth simulado: los tests nunca abren la página /captcha/ (ni una
// WebView ni un iframe).
import 'package:radici/core/captcha/captcha_service.dart';

/// Sin token, como cuando la página no responde: en producción (captcha
/// obligatorio, PR11) es el error de captcha; en desarrollo el login sigue sin
/// token (fail-open).
class NoCaptchaService implements CaptchaService {
  const NoCaptchaService();

  @override
  Future<String?> token({String? locale}) async => null;

  @override
  String? get lastFailure => 'test-no-token';
}

/// Siempre el mismo token: el captcha que anda (el de por defecto en
/// pumpRadiciApp, que arma la app en producción).
class TokenCaptchaService implements CaptchaService {
  const TokenCaptchaService();

  static const String value = 'captcha-test-token';

  @override
  Future<String?> token({String? locale}) async => value;

  @override
  String? get lastFailure => null;
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
  String? lastFailure;

  @override
  Future<String?> token({String? locale}) async {
    locales.add(locale);
    if (failWith) throw StateError('captcha roto');
    lastFailure = available ? null : 'app-timeout';
    return available ? 'captcha-token-$calls' : null;
  }
}

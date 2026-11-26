// El captcha de Auth antes de cada pedido que Auth protege (el código, la
// contraseña, el alta, la recuperación y el reenvío): un token nuevo por
// pedido, porque sirve una sola vez. Lo usan LoginController y
// PasswordAccessController.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/captcha/captcha_service.dart';

enum CaptchaOutcome { token, skipped, failed }

/// Pide un token de captcha. Devuelve el token; o, si no se pudo y Auth
/// todavía no lo exige, [CaptchaOutcome.skipped] (fail-open, ver
/// captcha_service.dart); o [CaptchaOutcome.failed] si no se pudo y es
/// obligatorio. Nunca lanza ni registra nada: el token y el motivo del fallo
/// no se loguean.
Future<(CaptchaOutcome, String?)> requestAuthCaptcha(
  Ref ref,
  String? locale,
) async {
  String? token;
  try {
    token = await ref.read(captchaServiceProvider).token(locale: locale);
  } on Object {
    token = null;
  }
  if (token != null) return (CaptchaOutcome.token, token);
  return ref.read(captchaRequiredProvider)
      ? (CaptchaOutcome.failed, null)
      : (CaptchaOutcome.skipped, null);
}

/// El motivo del último fallo del captcha (diagnóstico), o null.
String? lastAuthCaptchaFailure(Ref ref) {
  try {
    return ref.read(captchaServiceProvider).lastFailure;
  } on Object {
    return null;
  }
}

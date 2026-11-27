// Acceso con contraseña, alta, recuperación y reenvío (repositorio y captcha
// simulados): un token de captcha nuevo por pedido y avisos que no dicen si
// un email tiene cuenta.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/captcha/captcha_service.dart';
import 'package:radici/features/auth/application/password_access_controller.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

import '../../../support/captcha_fakes.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeCaptchaService captcha;
  late ProviderContainer container;

  PasswordAccessState state() => container.read(passwordAccessControllerProvider);
  PasswordAccessController controller() =>
      container.read(passwordAccessControllerProvider.notifier);

  ProviderContainer build({bool captchaRequired = false}) {
    final c = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        captchaServiceProvider.overrideWithValue(captcha),
        captchaRequiredProvider.overrideWithValue(captchaRequired),
      ],
    );
    // autoDispose: se mantiene vivo mientras dura el test.
    c.listen(passwordAccessControllerProvider, (_, _) {});
    return c;
  }

  setUp(() {
    auth = FakeAuthRepository();
    captcha = FakeCaptchaService();
    container = build();
  });

  group('entrar', () {
    test('email normalizado, la contraseña tal cual y un token de captcha', () async {
      await controller().signIn('  Cliente@Example.TEST ', auth.validPassword, locale: 'es');
      expect(auth.passwordRequests, ['signIn:cliente@example.test']);
      expect(auth.passwordCaptchaTokens, ['captcha-token-1']);
      expect(captcha.locales, ['es'], reason: 'el captcha, en el idioma de la app');
      expect(auth.user?.email, 'cliente@example.test');
      expect(state().busy, isFalse);
      expect(state().error, isNull);
    });

    test('email inválido o sin contraseña: el aviso sin captcha ni servidor', () async {
      await controller().signIn('cliente@', 'x');
      expect(state().error, AuthFailureKind.invalidEmail);
      await controller().signIn('cliente@example.test', '');
      expect(state().error, AuthFailureKind.passwordRequired);
      expect(captcha.calls, 0);
      expect(auth.passwordRequests, isEmpty);
    });

    test('contraseña incorrecta: invalidCredentials; cada intento, un token nuevo', () async {
      await controller().signIn('cliente@example.test', 'Sbagliata123');
      expect(state().error, AuthFailureKind.invalidCredentials);
      await controller().signIn('cliente@example.test', 'Sbagliata456');
      expect(auth.passwordCaptchaTokens, ['captcha-token-1', 'captcha-token-2']);
    });

    test('una cuenta de la cocina: kitchenCodeOnly', () async {
      auth.passwordFailure = AuthFailureKind.kitchenCodeOnly;
      await controller().signIn('evelyn@example.test', auth.validPassword);
      expect(state().error, AuthFailureKind.kitchenCodeOnly);
    });

    test('mientras espera al servidor está ocupado y no repite el pedido', () async {
      final gate = Completer<String?>();
      final slow = _GatedCaptcha(gate.future);
      container = ProviderContainer.test(
        retry: noRetry,
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          captchaServiceProvider.overrideWithValue(slow),
        ],
      )..listen(passwordAccessControllerProvider, (_, _) {});
      final first = controller().signIn('cliente@example.test', auth.validPassword);
      expect(state().busy, isTrue);
      await controller().signIn('cliente@example.test', auth.validPassword);
      controller().show(AccessView.forgot);
      expect(state().view, AccessView.signIn, reason: 'no cambia de formulario a mitad de un pedido');
      gate.complete('tok');
      await first;
      expect(slow.calls, 1);
      expect(auth.passwordRequests, ['signIn:cliente@example.test']);
    });
  });

  group('captcha', () {
    test('obligatorio y sin token: aviso con el motivo, sin llamar a Auth', () async {
      container = build(captchaRequired: true);
      captcha.available = false;
      await controller().requestReset('cliente@example.test');
      expect(state().error, AuthFailureKind.captcha);
      expect(state().errorDetail, 'app-timeout');
      expect(auth.passwordRequests, isEmpty);
    });

    test('Auth rechazó el token: el aviso del captcha con «auth»', () async {
      auth.emailFailure = AuthFailureKind.captcha;
      await controller().requestReset('cliente@example.test');
      expect(state().error, AuthFailureKind.captcha);
      expect(state().errorDetail, 'auth');
    });

    test('sin token y todavía no obligatorio (dev): sigue sin token', () async {
      captcha.available = false;
      await controller().requestReset('cliente@example.test');
      expect(auth.passwordRequests, ['reset:cliente@example.test']);
      expect(auth.passwordCaptchaTokens, [null]);
    });
  });

  // El alta es otra pantalla (SignUpController, sign_up_controller_test.dart).
  group('recuperación y reenvío: el mismo aviso exista o no la cuenta', () {
    test('«Password dimenticata?» confirma con resetSent', () async {
      await controller().requestReset('cliente@example.test');
      expect(auth.passwordRequests, ['reset:cliente@example.test']);
      expect(state().notice, AccessNotice.resetSent);
      expect(state().view, AccessView.forgot);
    });

    test('«Reinvia l\'email» repite el mismo pedido al mismo email, con otro token', () async {
      await controller().requestReset('cliente@example.test');
      await controller().resend(locale: 'en');
      expect(auth.passwordRequests, ['reset:cliente@example.test', 'reset:cliente@example.test']);
      expect(auth.passwordCaptchaTokens, ['captcha-token-1', 'captcha-token-2']);
      expect(state().resent, isTrue);
      expect(state().notice, AccessNotice.resetSent);
    });

    test('sin nada mandado, «Reinvia» no hace nada', () async {
      await controller().resend();
      expect(auth.passwordRequests, isEmpty);
      expect(captcha.calls, 0);
    });

    test('demasiados pedidos: rateLimited, sin perder la confirmación', () async {
      await controller().requestReset('cliente@example.test');
      auth.emailFailure = AuthFailureKind.rateLimited;
      await controller().resend();
      expect(state().error, AuthFailureKind.rateLimited);
      expect(state().notice, AccessNotice.resetSent);
      expect(state().resent, isFalse);
    });

    test('cambiar de formulario borra el error y el aviso, y deja el email escrito', () async {
      await controller().signIn('cliente@example.test', '');
      expect(state().error, AuthFailureKind.passwordRequired);
      controller().show(AccessView.forgot, email: ' Cliente@Example.test ');
      expect(state().error, isNull);
      expect(state().view, AccessView.forgot);
      expect(state().email, 'cliente@example.test');
    });
  });

  test('toString no lleva el email', () {
    const s = PasswordAccessState(email: 'cliente@example.test');
    expect(s.toString(), isNot(contains('cliente')));
  });
}

/// Un captcha que espera a [gate] antes de dar el token.
class _GatedCaptcha implements CaptchaService {
  _GatedCaptcha(this.gate);

  final Future<String?> gate;
  int calls = 0;

  @override
  String? get lastFailure => null;

  @override
  Future<String?> token({String? locale}) {
    calls++;
    return gate;
  }
}

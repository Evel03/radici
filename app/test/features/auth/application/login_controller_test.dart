// Login en dos pasos (email → código) con el repositorio simulado (mocktail).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:radici/core/captcha/captcha_service.dart';
import 'package:radici/core/env.dart';
import 'package:radici/features/auth/application/login_controller.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

import '../../../support/captcha_fakes.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';

void main() {
  late MockAuthRepository auth;
  late FakeCaptchaService captcha;
  late ProviderContainer container;

  LoginState state() => container.read(loginControllerProvider);
  LoginController controller() => container.read(loginControllerProvider.notifier);

  setUp(() {
    auth = MockAuthRepository();
    captcha = FakeCaptchaService();
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        captchaServiceProvider.overrideWithValue(captcha),
      ],
    );
    // autoDispose: se mantiene vivo mientras dura el test.
    container.listen(loginControllerProvider, (_, _) {});
  });

  test('email inválido: error sin llamar al servidor', () async {
    await controller().submitEmail('evelyn@');
    expect(state().error, AuthFailureKind.invalidEmail);
    expect(state().step, LoginStep.email);
    verifyZeroInteractions(auth);
  });

  test('email válido (normalizado) → paso del código', () async {
    when(() => auth.sendEmailCode(any(), locale: any(named: 'locale'), captchaToken: any(named: 'captchaToken'))).thenAnswer((_) async {});

    await controller().submitEmail('  Evelyn@Example.TEST ', locale: 'es');

    verify(() => auth.sendEmailCode('evelyn@example.test', locale: 'es', captchaToken: 'captcha-token-1')).called(1);
    expect(state().step, LoginStep.code);
    expect(state().email, 'evelyn@example.test');
    expect(state().locale, 'es');
    expect(state().busy, isFalse);
    expect(state().error, isNull);
  });

  test('mientras espera al servidor está ocupado y no repite el pedido', () async {
    when(() => auth.sendEmailCode(any(), locale: any(named: 'locale'), captchaToken: any(named: 'captchaToken'))).thenAnswer(
      (_) => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    final first = controller().submitEmail('evelyn@example.test');
    expect(state().busy, isTrue);
    await controller().submitEmail('evelyn@example.test');
    await first;
    verify(() => auth.sendEmailCode(any(), locale: any(named: 'locale'), captchaToken: any(named: 'captchaToken'))).called(1);
  });

  test('error al pedir el código: se queda en el email con el motivo', () async {
    when(
      () => auth.sendEmailCode(any(), locale: any(named: 'locale'), captchaToken: any(named: 'captchaToken')),
    ).thenThrow(const AuthFailure(AuthFailureKind.rateLimited));

    await controller().submitEmail('evelyn@example.test');

    expect(state().step, LoginStep.email);
    expect(state().error, AuthFailureKind.rateLimited);
    expect(state().busy, isFalse);
  });

  group('paso del código', () {
    setUp(() async {
      when(() => auth.sendEmailCode(any(), locale: any(named: 'locale'), captchaToken: any(named: 'captchaToken'))).thenAnswer((_) async {});
      await controller().submitEmail('evelyn@example.test', locale: 'it');
    });

    test('código con formato inválido: error sin llamar al servidor', () async {
      await controller().submitCode('12a');
      expect(state().error, AuthFailureKind.invalidCode);
      verifyNever(
        () => auth.verifyEmailCode(email: any(named: 'email'), code: any(named: 'code')),
      );
    });

    test('verifica el código (sin espacios) con el email del paso 1', () async {
      when(
        () => auth.verifyEmailCode(email: any(named: 'email'), code: any(named: 'code')),
      ).thenAnswer((_) async {});

      await controller().submitCode(' 123 456 ');

      verify(
        () => auth.verifyEmailCode(email: 'evelyn@example.test', code: '123456'),
      ).called(1);
      expect(state().error, isNull);
      expect(state().busy, isFalse);
    });

    test('código incorrecto o vencido', () async {
      when(
        () => auth.verifyEmailCode(email: any(named: 'email'), code: any(named: 'code')),
      ).thenThrow(const AuthFailure(AuthFailureKind.invalidCode));

      await controller().submitCode('000000');
      expect(state().error, AuthFailureKind.invalidCode);
      expect(state().step, LoginStep.code);
    });

    test('pedir otro código y cambiar de email', () async {
      await controller().resendCode();
      // El primer envío usó el token 1 y el reenvío pide uno nuevo (cada token sirve una vez).
      verify(() => auth.sendEmailCode('evelyn@example.test', locale: 'it', captchaToken: 'captcha-token-1')).called(1);
      verify(() => auth.sendEmailCode('evelyn@example.test', locale: 'it', captchaToken: 'captcha-token-2')).called(1);
      expect(state().codeResent, isTrue);

      controller().changeEmail();
      expect(state().step, LoginStep.email);
      expect(state().locale, 'it');
      expect(state().email, 'evelyn@example.test');
      expect(state().codeResent, isFalse);
    });
  });

  group('captcha de Auth', () {
    void stubSend() => when(
      () => auth.sendEmailCode(any(), locale: any(named: 'locale'), captchaToken: any(named: 'captchaToken')),
    ).thenAnswer((_) async {});

    test('pide un token por envío y se lo pasa al repositorio, con el idioma de la interfaz', () async {
      stubSend();
      await controller().submitEmail('evelyn@example.test', locale: 'es');
      expect(captcha.calls, 1);
      expect(captcha.locales, ['es']);
      verify(() => auth.sendEmailCode('evelyn@example.test', locale: 'es', captchaToken: 'captcha-token-1')).called(1);
    });

    test('no pide token si el email es inválido (no hay pedido a Auth)', () async {
      await controller().submitEmail('evelyn@');
      expect(captcha.calls, 0);
    });

    test('un envío que ya está en curso no pide otro token', () async {
      stubSend();
      final first = controller().submitEmail('evelyn@example.test');
      await controller().submitEmail('evelyn@example.test');
      await first;
      expect(captcha.calls, 1);
    });

    test('reenviar el código pide un token nuevo, también si el anterior fue bueno', () async {
      stubSend();
      await controller().submitEmail('evelyn@example.test', locale: 'it');
      await controller().resendCode();
      expect(captcha.calls, 2);
      verify(() => auth.sendEmailCode('evelyn@example.test', locale: 'it', captchaToken: 'captcha-token-2')).called(1);
    });

    test('fail-open (Auth todavía sin captcha): sin token el código se pide igual, sin token', () async {
      stubSend();
      captcha.available = false;
      await controller().submitEmail('evelyn@example.test', locale: 'it');
      verify(() => auth.sendEmailCode('evelyn@example.test', locale: 'it', captchaToken: null)).called(1);
      expect(state().step, LoginStep.code);
      expect(state().error, isNull);
    });

    test('fail-open también si el servicio de captcha se rompe (lanza)', () async {
      stubSend();
      captcha.failWith = true;
      await controller().submitEmail('evelyn@example.test');
      verify(() => auth.sendEmailCode('evelyn@example.test', locale: null, captchaToken: null)).called(1);
      expect(state().step, LoginStep.code);
    });

    test('obligatorio en producción y fail-open en desarrollo (PR11)', () {
      // Los tests corren sin --dart-define: APP_ENV=dev.
      expect(container.read(captchaRequiredProvider), isFalse);
      expect(captchaRequiredIn(const AppEnv(environment: AppEnvironment.prod)), isTrue);
      expect(captchaRequiredIn(const AppEnv(environment: AppEnvironment.dev)), isFalse);
      final prod = ProviderContainer.test(
        overrides: [appEnvProvider.overrideWithValue(const AppEnv(environment: AppEnvironment.prod))],
      );
      expect(prod.read(captchaRequiredProvider), isTrue);
    });

    group('con el captcha obligatorio (PR11)', () {
      setUp(() {
        container.dispose();
        container = ProviderContainer.test(
          retry: noRetry,
          overrides: [
            authRepositoryProvider.overrideWithValue(auth),
            captchaServiceProvider.overrideWithValue(captcha),
            captchaRequiredProvider.overrideWithValue(true),
          ],
        );
        container.listen(loginControllerProvider, (_, _) {});
      });

      test('con token: sale igual', () async {
        stubSend();
        await controller().submitEmail('evelyn@example.test');
        verify(() => auth.sendEmailCode('evelyn@example.test', locale: null, captchaToken: 'captcha-token-1')).called(1);
      });

      test('sin token: error de captcha, nada se manda a Auth y se puede reintentar', () async {
        stubSend();
        captcha.available = false;
        await controller().submitEmail('evelyn@example.test');
        expect(state().error, AuthFailureKind.captcha);
        expect(state().step, LoginStep.email);
        expect(state().busy, isFalse);
        verifyZeroInteractions(auth);

        captcha.available = true;
        await controller().submitEmail('evelyn@example.test');
        expect(state().step, LoginStep.code);
        expect(state().error, isNull);
      });

      test('sin token al reenviar: error de captcha y sigue en el paso del código', () async {
        stubSend();
        await controller().submitEmail('evelyn@example.test');
        captcha.available = false;
        await controller().resendCode();
        expect(state().error, AuthFailureKind.captcha);
        expect(state().step, LoginStep.code);
        expect(state().codeResent, isFalse);
      });
    });
  });

  test('el estado no muestra el email en toString', () {
    expect('${const LoginState(email: 'evelyn@example.test')}', isNot(contains('@')));
  });

  test('validaciones', () {
    expect(isValidEmail('a@b.it'), isTrue);
    expect(isValidEmail('a@b.c'), isFalse);
    expect(isValidEmail('a b@c.it'), isFalse);
    expect(normalizeOtp(' 12-34 56 '), '123456');
    expect(isValidOtp('123456'), isTrue);
    expect(isValidOtp('12345'), isFalse);
    expect(isValidOtp('12345678'), isTrue, reason: 'otp_length configurable');
    expect(isValidOtp('12345678901'), isFalse);
  });
}

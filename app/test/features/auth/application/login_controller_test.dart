// Login en dos pasos (email → código) con el repositorio simulado (mocktail).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/features/auth/application/login_controller.dart';
import 'package:mestolo/features/auth/data/auth_repository.dart';
import 'package:mestolo/features/auth/domain/auth_models.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';

void main() {
  late MockAuthRepository auth;
  late ProviderContainer container;

  LoginState state() => container.read(loginControllerProvider);
  LoginController controller() => container.read(loginControllerProvider.notifier);

  setUp(() {
    auth = MockAuthRepository();
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [authRepositoryProvider.overrideWithValue(auth)],
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
    when(() => auth.sendEmailCode(any(), locale: any(named: 'locale'))).thenAnswer((_) async {});

    await controller().submitEmail('  Evelyn@Example.TEST ', locale: 'es');

    verify(() => auth.sendEmailCode('evelyn@example.test', locale: 'es')).called(1);
    expect(state().step, LoginStep.code);
    expect(state().email, 'evelyn@example.test');
    expect(state().locale, 'es');
    expect(state().busy, isFalse);
    expect(state().error, isNull);
  });

  test('mientras espera al servidor está ocupado y no repite el pedido', () async {
    when(() => auth.sendEmailCode(any(), locale: any(named: 'locale'))).thenAnswer(
      (_) => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    final first = controller().submitEmail('evelyn@example.test');
    expect(state().busy, isTrue);
    await controller().submitEmail('evelyn@example.test');
    await first;
    verify(() => auth.sendEmailCode(any(), locale: any(named: 'locale'))).called(1);
  });

  test('error al pedir el código: se queda en el email con el motivo', () async {
    when(
      () => auth.sendEmailCode(any(), locale: any(named: 'locale')),
    ).thenThrow(const AuthFailure(AuthFailureKind.rateLimited));

    await controller().submitEmail('evelyn@example.test');

    expect(state().step, LoginStep.email);
    expect(state().error, AuthFailureKind.rateLimited);
    expect(state().busy, isFalse);
  });

  group('paso del código', () {
    setUp(() async {
      when(() => auth.sendEmailCode(any(), locale: any(named: 'locale'))).thenAnswer((_) async {});
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
      verify(() => auth.sendEmailCode('evelyn@example.test', locale: 'it')).called(2);
      expect(state().codeResent, isTrue);

      controller().changeEmail();
      expect(state().step, LoginStep.email);
      expect(state().locale, 'it');
      expect(state().email, 'evelyn@example.test');
      expect(state().codeResent, isFalse);
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

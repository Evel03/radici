// «Crear cuenta»: el alta con captcha, el código del email, la contraseña y los datos, y los reintentos.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/captcha/captcha_service.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/features/auth/application/sign_up_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';

import '../../../support/captcha_fakes.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';

SignUpForm _form({String phone = '3401234567', DateTime? birth}) => SignUpForm(
  firstName: 'Anna',
  lastName: 'Rota',
  phone: phone,
  birthDate: birth ?? DateTime(1990, 5, 17),
  email: ' Anna@Example.com ',
  password: 'Bergamo2027',
  repeat: 'Bergamo2027',
  privacyAccepted: true,
  season: Season.winter,
);

void main() {
  late FakeAuthRepository auth;
  late FakeAccountRepository accounts;
  late FakeCaptchaService captcha;
  late ProviderContainer container;

  SignUpState state() => container.read(signUpControllerProvider);
  SignUpController controller() =>
      container.read(signUpControllerProvider.notifier);

  setUp(() {
    auth = FakeAuthRepository();
    accounts = FakeAccountRepository(null);
    captcha = FakeCaptchaService();
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(accounts),
        captchaServiceProvider.overrideWithValue(captcha),
        captchaRequiredProvider.overrideWithValue(false),
        clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 27, 10)),
      ],
    );
  });

  test('con problemas en el formulario no pide nada', () async {
    await controller().submit(const SignUpForm(firstName: 'Anna'));
    expect(state().step, SignUpStep.form);
    expect(state().problems.keys, contains(SignUpField.lastName));
    expect(auth.passwordRequests, isEmpty);
    expect(captcha.calls, 0);
  });

  test(
    'el alta completa: captcha → signUp → código → contraseña → datos → listo',
    () async {
      await controller().submit(_form(), locale: 'es');
      expect(auth.passwordRequests, ['signUp:anna@example.com']);
      expect(auth.passwordCaptchaTokens, ['captcha-token-1']);
      expect(state().step, SignUpStep.code);
      expect(state().email, 'anna@example.com');
      expect(
        state().holdsRoute,
        isFalse,
        reason:
            'esperando el código, el router todavía no tiene nada que retener',
      );

      await controller().verify(' 1234 567 890 ');
      expect(
        auth.user?.email,
        'anna@example.com',
        reason: 'el código abrió la sesión',
      );
      expect(auth.newPasswords, ['Bergamo2027']);
      expect(accounts.savedDetails, [accountDetailsPayload(_form())]);
      expect(state().step, SignUpStep.done);
      expect(
        state().holdsRoute,
        isTrue,
        reason: 'la pantalla la lleva a su área, no el router',
      );

      controller().reset();
      expect(state().step, SignUpStep.form);
      expect(state().holdsRoute, isFalse);
    },
  );

  test('un código incorrecto (o con otra forma) no abre nada', () async {
    await controller().submit(_form());
    await controller().verify('12345');
    expect(state().error, AuthFailureKind.invalidCode);
    await controller().verify('0000000000');
    expect(state().error, AuthFailureKind.invalidCode);
    expect(state().step, SignUpStep.code);
    expect(auth.newPasswords, isEmpty);
    expect(accounts.savedDetails, isEmpty);
  });

  test('si falla la contraseña o la red al guardar, se queda «terminando» y reintenta solo lo que falta', () async {
    await controller().submit(_form());
    auth.setPasswordFailure = AuthFailureKind.network;
    await controller().verify(auth.validSignUpCode);
    expect(state().step, SignUpStep.finishing);
    expect(state().error, AuthFailureKind.network);
    expect(
      state().holdsRoute,
      isTrue,
      reason: 'la sesión ya está abierta: la pantalla no se va',
    );

    auth.setPasswordFailure = null;
    accounts.detailsFailure = const AccountFailure(
      AccountFailureKind.unavailable,
    );
    await controller().retryFinish();
    expect(auth.newPasswords, ['Bergamo2027']);
    expect(state().error, AuthFailureKind.network);

    accounts.detailsFailure = null;
    await controller().retryFinish();
    expect(auth.newPasswords, [
      'Bergamo2027',
    ], reason: 'la contraseña no se pone dos veces');
    expect(accounts.savedDetails, hasLength(1));
    expect(state().step, SignUpStep.done);
  });

  test('si la base rechaza un dato, vuelve al formulario con ese campo; al corregirlo, solo guarda los datos', () async {
    await controller().submit(_form());
    accounts.detailsFailure = const AccountDetailsRejected({
      SignUpField.underage,
    });
    await controller().verify(auth.validSignUpCode);
    expect(state().step, SignUpStep.form);
    expect(state().problems.keys, [SignUpField.underage]);

    accounts.detailsFailure = null;
    await controller().submit(_form(birth: DateTime(1985, 1, 1)));
    expect(auth.passwordRequests, [
      'signUp:anna@example.com',
    ], reason: 'no pide otra alta ni otro código');
    expect(auth.newPasswords, ['Bergamo2027']);
    expect(accounts.savedDetails.single['birth_date'], '1985-01-01');
    expect(state().step, SignUpStep.done);
  });

  test('«Reenviar el código» con otro captcha, y «Cambiar mis datos» vuelve al formulario', () async {
    await controller().submit(_form());
    await controller().resend();
    expect(auth.passwordRequests, [
      'signUp:anna@example.com',
      'resend:anna@example.com',
    ]);
    expect(auth.passwordCaptchaTokens, ['captcha-token-1', 'captcha-token-2']);
    expect(state().resent, isTrue);
    controller().editForm();
    expect(state().step, SignUpStep.form);
  });

  test('con las altas cerradas: el aviso, sin pasar al código', () async {
    auth.emailFailure = AuthFailureKind.signupClosed;
    await controller().submit(_form());
    expect(state().error, AuthFailureKind.signupClosed);
    expect(state().step, SignUpStep.form);
  });

  test('toString no lleva el email', () async {
    await controller().submit(_form());
    expect(state().toString(), isNot(contains('anna')));
  });
}

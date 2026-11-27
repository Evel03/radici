// «Cambia password»: la regla se revisa antes de llamar a Auth, y los errores
// de Auth llegan con su tipo.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/application/change_password_controller.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/password_rules.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';

void main() {
  late FakeAuthRepository auth;
  late ProviderContainer container;

  ChangePasswordState state() => container.read(changePasswordControllerProvider);
  Future<void> submit(String current, String next, [String? repeat]) => container
      .read(changePasswordControllerProvider.notifier)
      .submit(currentPassword: current, newPassword: next, repeatPassword: repeat ?? next);

  setUp(() {
    auth = FakeAuthRepository();
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [authRepositoryProvider.overrideWithValue(auth)],
    )..listen(changePasswordControllerProvider, (_, _) {});
  });

  test('cambia la contraseña con la actual y la nueva', () async {
    await submit('Vecchia1234', 'Nuova123456');
    expect(auth.passwordChanges, [('Vecchia1234', 'Nuova123456')]);
    expect(state().done, isTrue);
    expect(state().error, isNull);
    // Ya hecho: no se repite.
    await submit('Vecchia1234', 'Nuova123456');
    expect(auth.passwordChanges, hasLength(1));
  });

  test('sin la actual, con una nueva que no cumple la regla o igual a la actual: sin llamar a Auth', () async {
    await submit('', 'Nuova123456');
    expect(state().error, AuthFailureKind.passwordRequired);
    await submit('Vecchia1234', 'corta1');
    expect(state().problem, PasswordProblem.tooShort);
    expect(state().error, isNull);
    await submit('Vecchia1234', 'senzanumeri');
    expect(state().problem, PasswordProblem.lettersDigits);
    await submit('Uguale12345', 'Uguale12345');
    expect(state().error, AuthFailureKind.samePassword);
    expect(state().problem, isNull);
    expect(auth.passwordChanges, isEmpty);
  });

  test('la nueva escrita dos veces: si no coinciden no llama a Auth (la regla se avisa primero)', () async {
    await submit('Vecchia1234', 'Nuova123456', 'Nuova123465');
    expect(state().mismatch, isTrue);
    expect(state().problem, isNull);
    expect(state().error, isNull);
    await submit('Vecchia1234', 'corta1', 'otra');
    expect(state().problem, PasswordProblem.tooShort);
    expect(state().mismatch, isFalse);
    expect(auth.passwordChanges, isEmpty);

    await submit('Vecchia1234', 'Nuova123456', 'Nuova123456');
    expect(state().mismatch, isFalse);
    expect(auth.passwordChanges, [('Vecchia1234', 'Nuova123456')]);
  });

  test('los errores de Auth: la actual incorrecta, débil, de red', () async {
    for (final kind in [
      AuthFailureKind.wrongCurrentPassword,
      AuthFailureKind.weakPassword,
      AuthFailureKind.network,
    ]) {
      auth.changeFailure = kind;
      await submit('Vecchia1234', 'Nuova123456');
      expect(state().error, kind);
      expect(state().busy, isFalse);
      expect(state().done, isFalse);
    }
  });
}

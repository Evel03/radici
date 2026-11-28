// «Mi cuenta» (auth.md §20): guardar los datos (con las reglas del alta, sin el email ni la contraseña), la privacy
// cuando falta y borrar la cuenta.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/features/auth/application/my_account_controller.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';

SignUpForm _form({String phone = '3401234567', DateTime? birth, Season? season}) => SignUpForm(
  firstName: 'Anna',
  lastName: 'Rota',
  phone: phone,
  birthDate: birth ?? DateTime(1990, 5, 17),
  season: season,
);

const Map<String, Object?> _saved = {
  'first_name': 'Anna',
  'last_name': 'Rota',
  'phone': '+393401234567',
  'birth_date': '1990-05-17',
  'favorite_season': 'winter',
  'privacy_version': accountPrivacyVersion,
};

void main() {
  late FakeAuthRepository auth;
  late FakeAccountRepository accounts;
  late ProviderContainer container;

  MyAccountState state() => container.read(myAccountControllerProvider);
  MyAccountController controller() => container.read(myAccountControllerProvider.notifier);

  setUp(() {
    auth = FakeAuthRepository(user: const AppUser(id: 'client-1', email: 'anna@example.test'));
    accounts = FakeAccountRepository(const Account(role: AccountRole.client))..storedDetails = _saved;
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(accounts),
        clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 27, 10)),
      ],
    );
    // Los providers autoDispose siguen vivos mientras se los escucha.
    container.listen(myAccountControllerProvider, (_, _) {});
  });

  test('needsPrivacy: sin datos o con otra versión', () {
    expect(needsPrivacy(null), isTrue);
    expect(needsPrivacy({'privacy_version': '2026-11-20'}), isTrue);
    expect(needsPrivacy(_saved), isFalse);
  });

  test('accountDetailsProvider lee los datos guardados', () async {
    expect(await container.read(accountDetailsProvider.future), _saved);
  });

  test('con un dato mal no guarda nada y marca el campo', () async {
    await controller().save(_form(phone: '12'), current: _saved);
    expect(state().problems.keys, [SignUpField.phone]);
    expect(accounts.savedDetails, isEmpty);

    // Menor de edad hoy en Roma.
    await controller().save(_form(birth: DateTime(2009, 1, 1)), current: _saved);
    expect(state().problems.keys, contains(SignUpField.underage));
    expect(accounts.savedDetails, isEmpty);
  });

  test('guarda los datos (sin pedir la privacy ya aceptada) y vuelve a leerlos', () async {
    await container.read(accountDetailsProvider.future);
    await controller().save(_form(season: Season.summer), current: _saved);
    expect(state().saved, isTrue);
    expect(state().problems, isEmpty);
    expect(accounts.savedDetails.single, containsPair('phone', '+393401234567'));
    expect(accounts.savedDetails.single, containsPair('favorite_season', 'summer'));
    expect(accounts.savedDetails.single, containsPair('privacy_version', accountPrivacyVersion));
    expect(await container.read(accountDetailsProvider.future), containsPair('favorite_season', 'summer'));
  });

  test('sin datos guardados (o con otra versión) pide aceptar la privacy', () async {
    await controller().save(_form(), current: null);
    expect(state().problems.keys, [SignUpField.privacy]);
    expect(accounts.savedDetails, isEmpty);

    await controller().save(_form(), current: {..._saved, 'privacy_version': '2026-11-20'});
    expect(state().problems.keys, [SignUpField.privacy]);

    await controller().save(_form(), current: null, privacyAccepted: true);
    expect(state().saved, isTrue);
    expect(accounts.savedDetails, hasLength(1));
  });

  test('la base rechaza un campo → ese campo; sin conexión → failed', () async {
    accounts.detailsFailure = const AccountDetailsRejected({SignUpField.postalCode});
    await controller().save(_form(), current: _saved);
    expect(state().problems.keys, [SignUpField.postalCode]);
    expect(state().failed, isFalse);

    accounts.detailsFailure = const AccountFailure(AccountFailureKind.unavailable);
    await controller().save(_form(), current: _saved);
    expect(state().failed, isTrue);
    expect(state().saved, isFalse);
  });

  test('el estado no muestra los datos', () async {
    await controller().save(_form(phone: '12'), current: _saved);
    expect(state().toString(), isNot(contains('Anna')));
    expect(state().toString(), contains('phone'));
  });

  test('borrar la cuenta: la RPC y después salir', () async {
    container.read(sessionControllerProvider);
    await controller().deleteAccount();
    expect(accounts.deletes, 1);
    expect(state().deleted, isTrue);
    expect(container.read(sessionControllerProvider), isA<SignedOut>());
    expect(auth.user, isNull);
  });

  test('si no se pudo borrar, la sesión sigue abierta', () async {
    accounts.deleteFailure = const AccountFailure(AccountFailureKind.unavailable);
    await controller().deleteAccount();
    expect(accounts.deletes, 0);
    expect(state().failed, isTrue);
    expect(state().deleted, isFalse);
    expect(auth.user, isNotNull);
  });
}

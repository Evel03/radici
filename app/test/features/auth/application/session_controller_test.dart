// Sesión: del login al área que corresponde según el rol.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeAccountRepository accounts;

  ProviderContainer container() => ProviderContainer.test(
    retry: noRetry,
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      accountRepositoryProvider.overrideWithValue(accounts),
    ],
  );

  setUp(() {
    auth = FakeAuthRepository();
    accounts = FakeAccountRepository(chefAccountData);
  });

  test('sin sesión guardada: signedOut', () {
    final c = container();
    expect(c.read(sessionControllerProvider), const SessionState.signedOut());
    expect(c.read(currentChefProvider), isNull);
  });

  test('sesión guardada de la cocinera: cargando y después su área', () async {
    auth.user = chefUser;
    final c = container();
    expect(c.read(sessionControllerProvider), const SessionState.loading(chefUser));

    await pumpEventQueue();
    expect(
      c.read(sessionControllerProvider),
      const SessionState.chef(chefUser, chefAccount),
    );
    expect(c.read(currentChefProvider), chefAccount);
  });

  test('la sesión trae el idioma del perfil', () async {
    accounts.account = chefAccountData.copyWith(language: AppLanguage.es);
    auth.user = chefUser;
    final c = container();
    c.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
    expect(
      c.read(sessionControllerProvider),
      const SessionState.chef(chefUser, chefAccount, language: AppLanguage.es),
    );
  });

  test('cualquier otro rol va al área de clientes', () async {
    accounts.account = const Account(role: AccountRole.client);
    final c = container();
    c.listen(sessionControllerProvider, (_, _) {});

    const user = AppUser(id: 'u2', email: 'cliente@example.test');
    auth.emit(user);
    await pumpEventQueue();
    expect(c.read(sessionControllerProvider), const SessionState.client(user));
    expect(c.read(currentChefProvider), isNull);
  });

  test('error al leer la cuenta: failed, y reintentar la vuelve a leer', () async {
    accounts.failure = AccountFailureKind.unavailable;
    auth.user = chefUser;
    final c = container();
    c.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
    expect(
      c.read(sessionControllerProvider),
      const SessionState.failed(chefUser, AccountFailureKind.unavailable),
    );

    accounts.failure = null;
    await c.read(sessionControllerProvider.notifier).retry();
    expect(
      c.read(sessionControllerProvider),
      const SessionState.chef(chefUser, chefAccount),
    );
    expect(accounts.calls, 2);
  });

  test('el mismo usuario otra vez (token renovado) no vuelve a cargar', () async {
    auth.user = chefUser;
    final c = container();
    c.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
    auth.emit(chefUser);
    await pumpEventQueue();
    expect(accounts.calls, 1);
    expect(c.read(sessionControllerProvider), isA<ChefSession>());
  });

  test('al salir queda signedOut (también si la sesión se cierra sola)', () async {
    auth.user = chefUser;
    final c = container();
    c.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();

    await c.read(sessionControllerProvider.notifier).signOut();
    expect(c.read(sessionControllerProvider), const SessionState.signedOut());
    expect(auth.user, isNull);

    auth.emit(chefUser);
    await pumpEventQueue();
    expect(c.read(sessionControllerProvider), isA<ChefSession>());
    auth.emit(null);
    await pumpEventQueue();
    expect(c.read(sessionControllerProvider), const SessionState.signedOut());
  });

  test('salir antes de que termine la carga inicial: queda signedOut', () async {
    auth.user = chefUser;
    final c = container();
    c.listen(sessionControllerProvider, (_, _) {});
    // La carga de la cuenta está agendada pero todavía no corrió.
    await c.read(sessionControllerProvider.notifier).signOut();
    await pumpEventQueue();
    expect(c.read(sessionControllerProvider), const SessionState.signedOut());
  });

  test('si el usuario cambia mientras carga, gana el último', () async {
    final slow = _SlowAccounts();
    final c = ProviderContainer.test(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(slow),
      ],
    );
    c.listen(sessionControllerProvider, (_, _) {});

    auth.emit(chefUser);
    const other = AppUser(id: 'u2', email: 'otra@example.test');
    auth.emit(other);
    await pumpEventQueue();
    // Termina primero la carga del segundo usuario y después la del primero.
    slow.complete('u2', const Account(role: AccountRole.client));
    slow.complete(chefUser.id, chefAccountData);
    await pumpEventQueue();
    expect(c.read(sessionControllerProvider), const SessionState.client(other));
  });
}

/// Cuentas que se resuelven a mano, para simular respuestas desordenadas.
class _SlowAccounts implements AccountRepository {
  final Map<String, Completer<Account>> _pending = {};

  void complete(String userId, Account account) =>
      _pending.remove(userId)!.complete(account);

  @override
  Future<Account> fetchAccount(String userId) =>
      (_pending[userId] = Completer<Account>()).future;

  @override
  Future<void> updateLanguage({
    required String userId,
    required AppLanguage language,
  }) => throw UnimplementedError();
}

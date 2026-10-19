// Idioma de la interfaz: del perfil con sesión, del dispositivo sin sesión, y
// guardado en el dispositivo para el arranque en frío.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/settings/application/language_controller.dart';
import 'package:radici/features/settings/data/language_cache.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeAccountRepository accounts;
  late MemoryLanguageCache cache;
  late ProviderContainer container;

  AppLanguage? language() => container.read(languageControllerProvider);
  LanguageController controller() =>
      container.read(languageControllerProvider.notifier);

  /// Arranca como la app: algo escucha el idioma todo el tiempo.
  Future<void> start() async {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(accounts),
        languageCacheProvider.overrideWithValue(cache),
      ],
    );
    container.listen(appLocaleProvider, (_, _) {});
    await pumpEventQueue();
  }

  setUp(() {
    auth = FakeAuthRepository(user: chefUser);
    accounts = FakeAccountRepository(
      chefAccountData.copyWith(language: AppLanguage.es),
    );
    cache = MemoryLanguageCache();
  });

  test('sin sesión manda el dispositivo y se borra lo guardado', () async {
    auth = FakeAuthRepository();
    cache = MemoryLanguageCache((
      userId: chefUser.id,
      language: AppLanguage.en,
    ));
    await start();
    expect(language(), isNull);
    expect(container.read(appLocaleProvider), isNull);
    expect(cache.read(), isNull, reason: 'la sesión guardada ya no existe');
  });

  test(
    'con sesión manda el perfil, y se guarda para el próximo arranque',
    () async {
      await start();
      expect(language(), AppLanguage.es);
      expect(container.read(appLocaleProvider), const Locale('es'));
      expect(cache.read(), (userId: chefUser.id, language: AppLanguage.es));
    },
  );

  test(
    'arranque en frío: el idioma guardado se usa mientras carga la cuenta',
    () async {
      cache = MemoryLanguageCache((
        userId: chefUser.id,
        language: AppLanguage.en,
      ));
      accounts.pendingFetch = Completer<void>();
      await start();
      expect(
        container.read(sessionControllerProvider),
        const SessionState.loading(chefUser),
      );
      expect(language(), AppLanguage.en, reason: 'desde el primer cuadro');

      // El perfil (cambiado desde otro dispositivo) lo corrige.
      accounts.pendingFetch!.complete();
      await pumpEventQueue();
      expect(language(), AppLanguage.es);
      expect(cache.read(), (userId: chefUser.id, language: AppLanguage.es));
    },
  );

  test('lo guardado de otro usuario no se usa', () async {
    cache = MemoryLanguageCache((userId: 'otro', language: AppLanguage.en));
    accounts
      ..pendingFetch = Completer<void>()
      ..account = chefAccountData;
    await start();
    expect(language(), isNull);
    accounts.pendingFetch!.complete();
    await pumpEventQueue();
    expect(
      language(),
      isNull,
      reason: 'el perfil tampoco dice nada: dispositivo',
    );
  });

  test('sin conexión al arrancar: sigue el guardado', () async {
    cache = MemoryLanguageCache((
      userId: chefUser.id,
      language: AppLanguage.it,
    ));
    accounts.failure = AccountFailureKind.unavailable;
    await start();
    expect(container.read(sessionControllerProvider), isA<SessionFailed>());
    expect(language(), AppLanguage.it);
  });

  group('cambiar el idioma', () {
    test(
      'se ve enseguida, se guarda en el perfil y en el dispositivo',
      () async {
        await start();
        accounts.pendingUpdate = Completer<void>();

        final change = controller().setLanguage(AppLanguage.it);
        expect(language(), AppLanguage.it, reason: 'sin esperar al servidor');
        expect(cache.read(), (userId: chefUser.id, language: AppLanguage.it));

        accounts.pendingUpdate!.complete();
        await change;
        expect(accounts.savedLanguages, [
          (userId: chefUser.id, language: AppLanguage.it),
        ]);
        expect(language(), AppLanguage.it);
      },
    );

    test('si no se puede guardar, vuelve al del perfil y avisa', () async {
      await start();
      accounts.updateFailure = AccountFailureKind.unavailable;
      await expectLater(
        controller().setLanguage(AppLanguage.en),
        throwsA(isA<AccountFailure>()),
      );
      expect(language(), AppLanguage.es);
      expect(cache.read(), (userId: chefUser.id, language: AppLanguage.es));
    });

    test('dos cambios seguidos: llegan en orden y queda el último', () async {
      await start();
      accounts.pendingUpdate = Completer<void>();
      final first = controller().setLanguage(AppLanguage.it);
      final second = controller().setLanguage(AppLanguage.en);
      expect(language(), AppLanguage.en);

      accounts.pendingUpdate!.complete();
      await Future.wait([first, second]);
      expect(accounts.savedLanguages.map((s) => s.language), [
        AppLanguage.it,
        AppLanguage.en,
      ]);
      expect(language(), AppLanguage.en);
    });

    test('si falla el último, vuelve al último que se guardó bien', () async {
      await start();
      await controller().setLanguage(AppLanguage.it);
      accounts.updateFailure = AccountFailureKind.unavailable;
      await expectLater(
        controller().setLanguage(AppLanguage.en),
        throwsA(isA<AccountFailure>()),
      );
      expect(language(), AppLanguage.it);
    });

    test('elegir el idioma actual no hace nada', () async {
      await start();
      await controller().setLanguage(AppLanguage.es);
      expect(accounts.savedLanguages, isEmpty);
    });

    test('sin la cuenta cargada no hace nada', () async {
      accounts.pendingFetch = Completer<void>();
      await start();
      await controller().setLanguage(AppLanguage.it);
      expect(language(), isNull);
      expect(accounts.savedLanguages, isEmpty);
      accounts.pendingFetch!.complete();
    });
  });

  test('al salir vuelve al dispositivo y se borra lo guardado', () async {
    await start();
    await container.read(sessionControllerProvider.notifier).signOut();
    await pumpEventQueue();
    expect(language(), isNull);
    expect(cache.read(), isNull);
  });

  test('otro usuario entra: su perfil, nada del anterior', () async {
    await start();
    await container.read(sessionControllerProvider.notifier).signOut();
    accounts.account = const Account(
      role: AccountRole.client,
      language: AppLanguage.en,
    );
    auth.emit(const AppUser(id: 'cliente', email: 'c@example.test'));
    await pumpEventQueue();
    expect(language(), AppLanguage.en);
    expect(cache.read(), (userId: 'cliente', language: AppLanguage.en));
  });
}

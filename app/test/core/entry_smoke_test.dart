// Humo de cada entrada con la app completa: la de la cocina (/gestione/)
// llega a Hoy sin crear nada de la clienta; la de la clienta (/app/) llega a
// su área y no abre rutas de la cocina; y la cuenta de la otra entrada ve
// «ingresso» sin mezclarse. Más: el error de un link de Auth llega al login.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/router.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/auth/presentation/wrong_entry_screen.dart';
import 'package:radici/features/client/application/client_providers.dart';
import 'package:radici/features/client/presentation/client_shell.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/today/presentation/today_screen.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';
import '../support/request_fixtures.dart';

/// Anota el nombre de cada provider que se crea.
base class _Created extends ProviderObserver {
  final Set<String> names = {};

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    final name = context.provider.name;
    if (name != null) names.add(name);
  }
}

const _clientUser = AppUser(id: 'c1', email: 'cliente@example.test');

void main() {
  group('entrada de la cocina (/gestione/)', () {
    testWidgets('la cocinera llega a Hoy sin crear providers de la clienta', (
      tester,
    ) async {
      final created = _Created();
      await pumpRadiciApp(
        tester,
        isWeb: true,
        observers: [created],
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: chefUser),
          ),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(chefAccountData),
          ),
          chefRequestsRepositoryProvider.overrideWithValue(
            FakeChefRequestsRepository([buildRequest()]),
          ),
        ],
      );
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(created.names, isNot(contains('clientAccount')));
      expect(find.byType(ClientShell), findsNothing);
    });

    testWidgets('una clienta que abre /gestione/ ve «ingresso» y puede salir', (
      tester,
    ) async {
      final created = _Created();
      final auth = FakeAuthRepository(user: _clientUser);
      await pumpRadiciApp(
        tester,
        isWeb: true,
        observers: [created],
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(const Account(role: AccountRole.client)),
          ),
        ],
      );
      expect(find.byType(WrongEntryScreen), findsOneWidget);
      expect(
        find.text(
          "Questo accesso è riservato alla cucina. Per entrare come cliente usa l'app Radici (radicicucina.app/app/).",
        ),
        findsOneWidget,
      );
      // No se mezcla: ni el área de la clienta ni la de la cocina.
      expect(find.byType(ClientShell), findsNothing);
      expect(find.byType(TodayScreen), findsNothing);
      expect(created.names, isNot(contains('clientAccount')));

      await tester.tap(find.byKey(const ValueKey('wrong-entry-logout')));
      await tester.pumpAndSettle();
      expect(auth.user, isNull);
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets(
      'con una clienta, ni un enlace directo abre la cocina ni /area',
      (tester) async {
        final auth = FakeAuthRepository(user: _clientUser);
        final container = await pumpRadiciApp(
          tester,
          isWeb: true,
          overrides: [
            authRepositoryProvider.overrideWithValue(auth),
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository(const Account(role: AccountRole.client)),
            ),
            chefRequestsRepositoryProvider.overrideWithValue(
              FakeChefRequestsRepository([buildRequest()]),
            ),
          ],
        );
        for (final path in [
          '/oggi',
          '/richieste/abc',
          '/area',
          '/area/pedidos',
        ]) {
          container.read(routerProvider).go(path);
          await tester.pumpAndSettle();
          expect(find.byType(WrongEntryScreen), findsOneWidget, reason: path);
          expect(find.byType(TodayScreen), findsNothing, reason: path);
          expect(find.byType(ClientShell), findsNothing, reason: path);
        }
      },
    );
  });

  group('entrada de la clienta (/app/ y las apps)', () {
    testWidgets(
      'la clienta llega a su área; los providers de la clienta se crean ahí',
      (tester) async {
        final created = _Created();
        var kitchenRepositoryCreated = false;
        await pumpRadiciApp(
          tester,
          entry: AppEntry.client,
          isWeb: true,
          observers: [created],
          overrides: [
            authRepositoryProvider.overrideWithValue(
              FakeAuthRepository(user: _clientUser),
            ),
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository(const Account(role: AccountRole.client)),
            ),
            chefRequestsRepositoryProvider.overrideWith((ref) {
              kitchenRepositoryCreated = true;
              return FakeChefRequestsRepository(const []);
            }),
          ],
        );
        expect(find.byType(ClientShell), findsOneWidget);
        expect(created.names, contains('clientAccount'));
        // La bandeja de la cocina ni se mira.
        expect(kitchenRepositoryCreated, isFalse);
      },
    );

    testWidgets('no abre ninguna ruta de la cocina, ni con enlace directo', (
      tester,
    ) async {
      var kitchenRepositoryCreated = false;
      final container = await pumpRadiciApp(
        tester,
        entry: AppEntry.client,
        isWeb: true,
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: _clientUser),
          ),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(const Account(role: AccountRole.client)),
          ),
          chefRequestsRepositoryProvider.overrideWith((ref) {
            kitchenRepositoryCreated = true;
            return FakeChefRequestsRepository(const []);
          }),
        ],
      );
      for (final path in [
        '/oggi',
        '/richieste',
        '/richieste/abc',
        '/agenda',
        '/impostazioni',
        '/altro/piatti',
        '/sessioni/abc/menu',
      ]) {
        container.read(routerProvider).go(path);
        await tester.pumpAndSettle();
        expect(find.byType(ClientShell), findsOneWidget, reason: path);
        expect(find.byType(TodayScreen), findsNothing, reason: path);
      }
      expect(kitchenRepositoryCreated, isFalse);
    });

    testWidgets(
      'sin sesión, un enlace de la cocina pide login y no recuerda la ruta de la cocina',
      (tester) async {
        final container = await pumpRadiciApp(
          tester,
          entry: AppEntry.client,
          isWeb: true,
          overrides: [
            authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository(const Account(role: AccountRole.client)),
            ),
          ],
        );
        container.read(routerProvider).go('/richieste/abc');
        await tester.pumpAndSettle();
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(
          container
              .read(routerProvider)
              .routerDelegate
              .currentConfiguration
              .uri
              .toString(),
          '/accedi',
        );
      },
    );

    testWidgets(
      'la cuenta de la cocina que abre /app/ ve «ingresso»: sin Hoy y sin avisos de pedidos',
      (tester) async {
        var kitchenRepositoryCreated = false;
        final auth = FakeAuthRepository(user: chefUser);
        await pumpRadiciApp(
          tester,
          entry: AppEntry.client,
          isWeb: true,
          overrides: [
            authRepositoryProvider.overrideWithValue(auth),
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository(chefAccountData),
            ),
            chefRequestsRepositoryProvider.overrideWith((ref) {
              kitchenRepositoryCreated = true;
              return FakeChefRequestsRepository([buildRequest()]);
            }),
          ],
        );
        expect(find.byType(WrongEntryScreen), findsOneWidget);
        expect(
          find.text(
            'Questo account è della cucina: entra da radicicucina.app/gestione/.',
          ),
          findsOneWidget,
        );
        expect(find.byType(TodayScreen), findsNothing);
        expect(find.byType(ClientShell), findsNothing);
        expect(kitchenRepositoryCreated, isFalse);

        await tester.tap(find.byKey(const ValueKey('wrong-entry-logout')));
        await tester.pumpAndSettle();
        expect(auth.user, isNull);
      },
    );

    testWidgets('en nativo (sin web) la clienta entra igual', (tester) async {
      await pumpRadiciApp(
        tester,
        entry: AppEntry.client,
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: _clientUser),
          ),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(const Account(role: AccountRole.client)),
          ),
        ],
      );
      expect(find.byType(ClientShell), findsOneWidget);
    });
  });

  group('app nativa (auto): las dos cuentas', () {
    testWidgets('la cocina llega a Hoy sin crear providers de la clienta', (
      tester,
    ) async {
      final created = _Created();
      await pumpRadiciApp(
        tester,
        entry: AppEntry.auto,
        observers: [created],
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: chefUser),
          ),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(chefAccountData),
          ),
          chefRequestsRepositoryProvider.overrideWithValue(
            FakeChefRequestsRepository([buildRequest()]),
          ),
        ],
      );
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(find.byType(WrongEntryScreen), findsNothing);
      expect(created.names, isNot(contains('clientAccount')));
    });

    testWidgets('la clienta llega a /area sin crear providers de la cocina', (
      tester,
    ) async {
      var kitchenRepositoryCreated = false;
      final container = await pumpRadiciApp(
        tester,
        entry: AppEntry.auto,
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: _clientUser),
          ),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(const Account(role: AccountRole.client)),
          ),
          chefRequestsRepositoryProvider.overrideWith((ref) {
            kitchenRepositoryCreated = true;
            return FakeChefRequestsRepository(const []);
          }),
        ],
      );
      expect(find.byType(ClientShell), findsOneWidget);
      expect(find.byType(WrongEntryScreen), findsNothing);
      expect(container.read(kitchenAlertsEnabledProvider), isFalse);
      for (final path in ['/oggi', '/richieste/abc', '/agenda']) {
        container.read(routerProvider).go(path);
        await tester.pumpAndSettle();
        expect(find.byType(ClientShell), findsOneWidget, reason: path);
        expect(find.byType(TodayScreen), findsNothing, reason: path);
      }
      expect(kitchenRepositoryCreated, isFalse);
    });

    testWidgets('salir y entrar con la otra cuenta no deja nada de la anterior', (
      tester,
    ) async {
      final auth = FakeAuthRepository(user: chefUser);
      final accounts = FakeAccountRepository(chefAccountData);
      final requests = FakeChefRequestsRepository([buildRequest()]);
      final container = await pumpRadiciApp(
        tester,
        entry: AppEntry.auto,
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          accountRepositoryProvider.overrideWithValue(accounts),
          chefRequestsRepositoryProvider.overrideWithValue(requests),
        ],
      );
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(container.read(kitchenAlertsEnabledProvider), isTrue);
      expect(container.read(chefInboxProvider).value, isNotEmpty);

      // Sale la cocina y entra una clienta.
      await container.read(sessionControllerProvider.notifier).signOut();
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      accounts.account = const Account(role: AccountRole.client);
      auth.emit(_clientUser);
      await tester.pumpAndSettle();
      expect(find.byType(ClientShell), findsOneWidget);
      expect(container.read(kitchenAlertsEnabledProvider), isFalse);
      expect(container.read(chefInboxProvider).value, isEmpty);
      expect(container.read(currentChefProvider), isNull);

      // Y al revés: sale la clienta y vuelve la cocina.
      await container.read(sessionControllerProvider.notifier).signOut();
      await tester.pumpAndSettle();
      accounts.account = chefAccountData;
      auth.emit(chefUser);
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(container.read(kitchenAlertsEnabledProvider), isTrue);
      expect(container.read(clientAccountProvider), isNull);
    });
  });

  group('errores de Auth en el login', () {
    testWidgets(
      '/app/: un link con error se dice en el login y se borra al entrar con la contraseña',
      (tester) async {
        final auth = FakeAuthRepository();
        await pumpRadiciApp(
          tester,
          entry: AppEntry.client,
          isWeb: true,
          overrides: [
            authRepositoryProvider.overrideWithValue(auth),
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository(const Account(role: AccountRole.client)),
            ),
          ],
        );
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(find.byKey(const ValueKey('login-link-error')), findsNothing);

        auth.emitFailure(AuthFailureKind.unknown);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('login-link-error')), findsOneWidget);
        expect(
          find.text(
            'Il link di accesso non è valido o è scaduto. Prova di nuovo ad accedere.',
          ),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const ValueKey('access-email')),
          'cliente@example.test',
        );
        await tester.enterText(
          find.byKey(const ValueKey('access-password')),
          auth.validPassword,
        );
        await tester.tap(find.byKey(const ValueKey('access-sign-in')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('login-link-error')), findsNothing);
        expect(auth.passwordRequests, ['signIn:cliente@example.test']);
        expect(auth.sentTo, isEmpty, reason: 'en /app/ no hay código');
      },
    );

    testWidgets(
      '/gestione/: un link con error se dice en el login y se borra al pedir el código',
      (tester) async {
        final auth = FakeAuthRepository();
        await pumpRadiciApp(
          tester,
          isWeb: true,
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
        );
        auth.emitFailure(AuthFailureKind.unknown);
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Il link di accesso non è valido o è scaduto. Richiedi un nuovo codice.',
          ),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const ValueKey('login-email')),
          'evelyn@example.test',
        );
        await tester.tap(find.byKey(const ValueKey('login-send-code')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('login-link-error')), findsNothing);
        expect(auth.sentTo, ['evelyn@example.test']);
      },
    );
  });
}

// Humo de la app completa: arranque, idioma, navegación, aviso de backend y
// a qué área va cada usuario.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/app.dart';
import 'package:radici/core/env.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/presentation/client_area_screen.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/auth/presentation/session_screen.dart';
import 'package:radici/features/quote/presentation/quote_calculator_screen.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';

import 'support/fakes.dart';
import 'support/pump_app.dart';
import 'support/request_fixtures.dart';

const _devWithoutBackend = AppEnv(environment: AppEnvironment.dev);
const _prodWithoutBackend = AppEnv(environment: AppEnvironment.prod);

Future<void> _pumpApp(
  WidgetTester tester, {
  AppEnv env = _devWithoutBackend,
  List<Locale> deviceLocales = const [Locale('it', 'IT')],
}) async {
  tester.platformDispatcher.localesTestValue = deviceLocales;
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(
    ProviderScope(
      retry: noRetry,
      overrides: [appEnvProvider.overrideWithValue(env)],
      child: const RadiciApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('arranca en el inicio, en italiano', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Cucina di casa, a casa tua'), findsOneWidget);
    expect(find.text('Calcola preventivo'), findsOneWidget);
    expect(find.text('Accedi'), findsOneWidget);
  });

  testWidgets('con un idioma no soportado usa el italiano', (tester) async {
    await _pumpApp(tester, deviceLocales: const [Locale('de', 'DE')]);
    expect(find.text('Calcola preventivo'), findsOneWidget);
  });

  testWidgets('con el dispositivo en español usa el español', (tester) async {
    await _pumpApp(tester, deviceLocales: const [Locale('es', 'AR')]);
    expect(find.text('Calcular presupuesto'), findsOneWidget);
  });

  testWidgets('navega a la calculadora y vuelve', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('home-quote')));
    await tester.pumpAndSettle();
    expect(find.byType(QuoteCalculatorScreen), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(QuoteCalculatorScreen), findsNothing);
  });

  testWidgets('sin backend, el login avisa que el servicio no está configurado', (
    tester,
  ) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('home-login')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    // En el teléfono se llega desde el inicio: se puede volver.
    expect(find.byType(BackButton), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('login-email')),
      'evelyn@example.test',
    );
    await tester.tap(find.byKey(const ValueKey('login-send-code')));
    await tester.pumpAndSettle();
    expect(
      find.text("Il servizio non è configurato in questa versione dell'app."),
      findsOneWidget,
    );
  });

  testWidgets('en dev sin backend muestra el aviso', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Backend non configurato'), findsOneWidget);
  });

  testWidgets('en prod no muestra el aviso', (tester) async {
    await _pumpApp(tester, env: _prodWithoutBackend);
    expect(find.text('Backend non configurato'), findsNothing);
  });

  group('a qué área va cada usuario', () {
    testWidgets('la cocinera con sesión guardada entra directo a Richieste', (
      tester,
    ) async {
      await pumpRadiciApp(
        tester,
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
      expect(find.byType(InboxScreen), findsOneWidget);
    });

    testWidgets('otro usuario ve el área de clientes y puede salir', (
      tester,
    ) async {
      final auth = FakeAuthRepository(
        user: const AppUser(id: 'c1', email: 'cliente@example.test'),
      );
      await pumpRadiciApp(
        tester,
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(const Account(role: AccountRole.client)),
          ),
        ],
      );
      expect(find.byType(ClientAreaScreen), findsOneWidget);
      expect(find.text("L'area clienti è in preparazione"), findsOneWidget);
      // Debajo del texto: el selector de idioma y el botón para salir.
      expect(find.byKey(const ValueKey('language-selector')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('client-area-logout')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('client-area-logout')));
      await tester.pumpAndSettle();
      expect(auth.user, isNull);
      expect(find.text('Cucina di casa, a casa tua'), findsOneWidget);
    });

    testWidgets('si no se puede leer la cuenta: error con reintentar', (
      tester,
    ) async {
      final accounts = FakeAccountRepository(chefAccountData)
        ..failure = AccountFailureKind.unavailable;
      await pumpRadiciApp(
        tester,
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: chefUser),
          ),
          accountRepositoryProvider.overrideWithValue(accounts),
          chefRequestsRepositoryProvider.overrideWithValue(
            FakeChefRequestsRepository(const []),
          ),
        ],
      );
      expect(find.byType(SessionScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('session-error')), findsOneWidget);

      accounts.failure = null;
      await tester.tap(find.byKey(const ValueKey('session-retry')));
      await tester.pumpAndSettle();
      expect(find.byType(InboxScreen), findsOneWidget);
    });

    testWidgets('web (/gestione/): sin sesión arranca en el login', (
      tester,
    ) async {
      await pumpRadiciApp(tester, isWeb: true);
      expect(find.byType(LoginScreen), findsOneWidget);
      // Es la primera pantalla: sin flecha de volver (llevaría al mismo login).
      expect(find.byType(BackButton), findsNothing);
    });
  });
}

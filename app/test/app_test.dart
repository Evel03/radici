// Humo de la app completa: arranque, idioma, navegación, aviso de backend y
// a qué área va cada usuario.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/app.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/captcha/captcha_service.dart';
import 'package:radici/core/env.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/auth/presentation/session_screen.dart';
import 'package:radici/features/client/presentation/client_shell.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/today/presentation/today_screen.dart';

import 'support/captcha_fakes.dart';
import 'support/fakes.dart';
import 'support/pump_app.dart';
import 'support/request_fixtures.dart';

const _devWithoutBackend = AppEnv(environment: AppEnvironment.dev);
const _prodWithoutBackend = AppEnv(environment: AppEnvironment.prod);

Future<void> _pumpApp(
  WidgetTester tester, {
  AppEnv env = _devWithoutBackend,
  List<Locale> deviceLocales = const [Locale('it', 'IT')],
  LinkLauncher? links,
  String? initialRoute,
}) async {
  if (initialRoute != null) {
    tester.platformDispatcher.defaultRouteNameTestValue = initialRoute;
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
  }
  tester.platformDispatcher.localesTestValue = deviceLocales;
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(
    ProviderScope(
      retry: noRetry,
      overrides: [
        appEnvProvider.overrideWithValue(env),
        // Sin el navegador del sistema: en los tests el captcha no abre nada.
        captchaServiceProvider.overrideWithValue(const NoCaptchaService()),
        if (links != null) linkLauncherProvider.overrideWithValue(links),
      ],
      child: const RadiciApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('arranca en el inicio, en italiano', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Cucina di casa, a casa tua'), findsOneWidget);
    // La compra la hace el cliente, no Evelyn.
    expect(find.textContaining('La spesa la fai tu, con la lista che ti manda lei.'), findsOneWidget);
    expect(find.textContaining('Evelyn fa la spesa'), findsNothing);
    expect(find.text('Richiedi un preventivo'), findsOneWidget);
    expect(find.text('Accedi'), findsOneWidget);
  });

  testWidgets('con un idioma no soportado usa el italiano', (tester) async {
    await _pumpApp(tester, deviceLocales: const [Locale('de', 'DE')]);
    expect(find.text('Richiedi un preventivo'), findsOneWidget);
  });

  testWidgets('con el dispositivo en español usa el español', (tester) async {
    await _pumpApp(tester, deviceLocales: const [Locale('es', 'AR')]);
    expect(find.text('Pedir presupuesto'), findsOneWidget);
  });

  testWidgets('«Richiedi un preventivo» abre el formulario de la web, en el idioma de la app', (tester) async {
    final links = FakeLinkLauncher();
    await _pumpApp(tester, links: links, deviceLocales: const [Locale('es', 'ES')]);
    await tester.tap(find.byKey(const ValueKey('home-request')));
    await tester.pumpAndSettle();
    expect(links.launched, [Uri.parse('https://radicicucina.app/richiesta/?lang=es')]);
  });

  // Desde el 22/11/2026 la tarifa es solo la referencia de Evelyn: sin sesión
  // la app no muestra ningún precio, y la calculadora pública ya no existe.
  for (final locale in const [Locale('it', 'IT'), Locale('es', 'ES'), Locale('en', 'GB')]) {
    testWidgets('sin sesión no hay precios en el inicio (${locale.languageCode})', (tester) async {
      await _pumpApp(tester, deviceLocales: [locale]);
      expect(find.textContaining('€'), findsNothing);
      expect(find.byKey(const ValueKey('home-quote')), findsNothing);
    });
  }

  testWidgets('/preventivo ya no existe: sin calculadora ni precios', (tester) async {
    await _pumpApp(tester, initialRoute: '/preventivo');
    expect(find.textContaining('€'), findsNothing);
    expect(find.byKey(const ValueKey('home-request')), findsNothing);
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
    testWidgets('la cocinera con sesión guardada entra directo a Hoy', (
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
      expect(find.byType(TodayScreen), findsOneWidget);
    });

    testWidgets('la clienta, en su entrada, ve su área y puede salir', (
      tester,
    ) async {
      final auth = FakeAuthRepository(
        user: const AppUser(id: 'c1', email: 'cliente@example.test'),
      );
      await pumpRadiciApp(
        tester,
        entry: AppEntry.client,
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(const Account(role: AccountRole.client)),
          ),
        ],
      );
      expect(find.byType(ClientShell), findsOneWidget);
      expect(find.text("L'area clienti è in preparazione"), findsOneWidget);
      // Debajo del texto: el selector de idioma y el botón para salir.
      expect(find.byKey(const ValueKey('language-selector')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('client-area-logout')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('client-area-logout')));
      await tester.pumpAndSettle();
      expect(auth.user, isNull);
      // Sale al login (como la cocina al salir de una ruta de su área).
      expect(find.byType(LoginScreen), findsOneWidget);
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
      expect(find.byType(TodayScreen), findsOneWidget);
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

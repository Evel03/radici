// Aviso de Safari, arriba del login y del área de Evelyn: el botón del email
// abre Safari, que tiene otra sesión que la app de la pantalla de inicio.
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/app.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/env.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/web_app/data/published_build_repository.dart';
import 'package:radici/features/web_app/domain/install_hint.dart';

import '../../../support/browser_fakes.dart';
import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/text_input_guard.dart';

void main() {
  late FakeBrowser browser;

  Future<void> openLogin(
    WidgetTester tester, {
    Locale locale = const Locale('it', 'IT'),
  }) async {
    setSurfaceSize(tester, const Size(375, 667));
    await pumpRadiciApp(
      tester,
      isWeb: true,
      deviceLocales: [locale],
      overrides: [
        authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        chefRequestsRepositoryProvider.overrideWithValue(
          FakeChefRequestsRepository(const []),
        ),
        browserProvider.overrideWithValue(browser),
      ],
    );
  }

  Finder hint() => find.byKey(const ValueKey('install-hint'));
  Finder closeButton() => find.byKey(const ValueKey('install-hint-close'));

  setUp(() => browser = FakeBrowser(info: iPhoneInSafari));

  testWidgets('arranque: el aviso llega en el segundo cuadro, así un cambio de foco antes del '
      'primer layout no lo encuentra sin medir', (tester) async {
    // En la web, runApp arma la app antes del primer layout, y en ese momento
    // el foco de la página puede pedir el primer elemento por orden de
    // lectura, que mide los botones: el del aviso todavía no tiene tamaño
    // («RenderBox was not laid out», visto en Edge con /gestione/).
    setSurfaceSize(tester, const Size(375, 667));
    tester.platformDispatcher.localesTestValue = const [Locale('it', 'IT')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          appEnvProvider.overrideWithValue(
            const AppEnv(environment: AppEnvironment.prod),
          ),
          isWebProvider.overrideWithValue(true),
          clockProvider.overrideWithValue(() => testNow),
          authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(chefAccountData),
          ),
          chefRequestsRepositoryProvider.overrideWithValue(
            FakeChefRequestsRepository(const []),
          ),
          browserProvider.overrideWithValue(browser),
        ],
        child: const RadiciApp(),
      ),
      phase: EnginePhase.build,
    );
    expect(hint(), findsNothing);
    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.focused,
        direction: ViewFocusDirection.forward,
      ),
    );

    await tester.pumpAndSettle();
    expect(hint(), findsOneWidget);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('login en Safari del iPhone: el aviso arriba, sin tapar el campo del email', (
    tester,
  ) async {
    await openLogin(tester);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(
      find.text(
        "Per non dover accedere di nuovo, apri Radici dall'icona nella "
        'schermata Home.',
      ),
      findsOneWidget,
    );
    expect(
      tester.getBottomLeft(hint()).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(AppBar)).dy),
    );
    expect(find.byKey(const ValueKey('login-email')).hitTestable(), findsOneWidget);
    expectReadableInputs(tester);
    expect(tester.getSize(closeButton()).height, greaterThanOrEqualTo(48));
  });

  testWidgets('«Chiudi» lo cierra y lo guarda en el dispositivo', (tester) async {
    await openLogin(tester);

    await tester.tap(closeButton());
    await tester.pumpAndSettle();
    expect(hint(), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(browser.flags, {installHintDismissedKey: '1'});
  });

  testWidgets('ya cerrado antes en este dispositivo: no vuelve', (tester) async {
    browser.flags[installHintDismissedKey] = '1';
    await openLogin(tester);
    expect(hint(), findsNothing);
  });

  testWidgets('en la app instalada no aparece', (tester) async {
    browser.info = const BrowserInfo(
      userAgent: iPhoneSafari,
      platform: 'iPhone',
      maxTouchPoints: 5,
      navigatorStandalone: true,
      displayModeStandalone: true,
    );
    await openLogin(tester);
    expect(hint(), findsNothing);
  });

  testWidgets('con la sesión abierta en Safari también, en español', (
    tester,
  ) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      deviceLocales: const [Locale('es', 'AR')],
      overrides: [browserProvider.overrideWithValue(browser)],
    );

    expect(find.byType(InboxScreen), findsOneWidget);
    expect(
      find.text(
        'Para no volver a entrar, abre Radici desde el ícono de tu pantalla de '
        'inicio.',
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: hint(), matching: find.text('Cerrar')),
      findsOneWidget,
    );
  });

  testWidgets('en inglés', (tester) async {
    await openLogin(tester, locale: const Locale('en', 'GB'));
    expect(
      find.text(
        'To avoid signing in again, open Radici from the icon on your Home '
        'Screen.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('con una versión nueva en Safari: los dos avisos, primero la versión', (
    tester,
  ) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      overrides: [
        browserProvider.overrideWithValue(browser),
        buildIdProvider.overrideWithValue('abc1234'),
        publishedBuildRepositoryProvider.overrideWithValue(
          FakePublishedBuildRepository('def5678'),
        ),
      ],
    );

    final banner = find.byKey(const ValueKey('update-banner'));
    expect(banner, findsOneWidget);
    expect(hint(), findsOneWidget);
    expect(
      tester.getBottomLeft(banner).dy,
      lessThanOrEqualTo(tester.getTopLeft(hint()).dy),
    );
    expect(
      tester.getBottomLeft(hint()).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(AppBar)).dy),
    );
  });
}

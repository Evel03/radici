// Login con código por email, de punta a punta en la app (repos falsos).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/captcha/captcha_service.dart';
import 'package:radici/core/radici_logo.dart';
import 'package:radici/core/router.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';
import 'package:radici/features/today/presentation/today_screen.dart';

import '../../../support/captcha_fakes.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/text_input_guard.dart';

void main() {
  late FakeAuthRepository auth;

  Future<ProviderContainer> pumpLogin(
    WidgetTester tester, {
    Locale locale = const Locale('it', 'IT'),
    bool isWeb = true,
    List<Override> overrides = const [],
    CaptchaService captcha = const TokenCaptchaService(),
  }) {
    setSurfaceSize(tester, const Size(400, 900));
    auth = FakeAuthRepository();
    return pumpRadiciApp(
      tester,
      isWeb: isWeb,
      captcha: captcha,
      deviceLocales: [locale],
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        // El email del código es el de Evelyn: entra como cocinera.
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        chefRequestsRepositoryProvider.overrideWithValue(
          FakeChefRequestsRepository([buildRequest(id: 'req-42')]),
        ),
        ...overrides,
      ],
    );
  }

  Future<void> enterEmail(WidgetTester tester, String email) async {
    await tester.enterText(find.byKey(const ValueKey('login-email')), email);
    await tester.tap(find.byKey(const ValueKey('login-send-code')));
    await tester.pumpAndSettle();
  }

  testWidgets('email → código → entra a Hoy, el inicio de la cocinera', (tester) async {
    await pumpLogin(tester);
    expect(find.byType(LoginScreen), findsOneWidget);
    // El logotipo arriba: en la web es la primera pantalla.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('login-brand')),
        matching: find.text('Radici'),
      ),
      findsOneWidget,
    );
    expect(find.byType(RadiciLogo), findsOneWidget);

    await enterEmail(tester, 'Evelyn@Example.test');
    expect(auth.sentTo, ['evelyn@example.test']);
    expect(auth.sentLocales, ['it'], reason: 'el email del código, en italiano');
    expect(
      find.text(
        'Ti abbiamo inviato un codice a evelyn@example.test. Scrivilo qui sotto.',
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const ValueKey('login-code')), '123456');
    await tester.tap(find.byKey(const ValueKey('login-verify')));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsNothing);
    expect(find.byType(TodayScreen), findsOneWidget);
  });

  testWidgets('email inválido: mensaje y no se pide código', (tester) async {
    await pumpLogin(tester);
    await enterEmail(tester, 'evelyn@');
    expect(find.text('Scrivi un indirizzo email valido.'), findsOneWidget);
    expect(auth.sentTo, isEmpty);
  });

  testWidgets('código incorrecto: mensaje y sigue en el paso del código', (
    tester,
  ) async {
    await pumpLogin(tester);
    await enterEmail(tester, 'evelyn@example.test');
    await tester.enterText(find.byKey(const ValueKey('login-code')), '000000');
    await tester.tap(find.byKey(const ValueKey('login-verify')));
    await tester.pumpAndSettle();

    expect(find.text('Il codice non è corretto o è scaduto.'), findsOneWidget);
    expect(find.byKey(const ValueKey('login-code')), findsOneWidget);
  });

  testWidgets('el campo del código solo acepta cifras', (tester) async {
    await pumpLogin(tester);
    await enterEmail(tester, 'evelyn@example.test');
    await tester.enterText(find.byKey(const ValueKey('login-code')), '12ab34');
    final field = tester.widget<TextField>(find.byKey(const ValueKey('login-code')));
    expect(field.controller!.text, '1234');
  });

  testWidgets('los campos tienen letra de 16 px o más (en el iPhone no hace zoom)', (
    tester,
  ) async {
    await pumpLogin(tester);
    expectReadableInputs(tester);
    await enterEmail(tester, 'evelyn@example.test');
    expectReadableInputs(tester);
  });

  testWidgets('pedir otro código y volver a cambiar el email', (tester) async {
    await pumpLogin(tester);
    await enterEmail(tester, 'evelyn@example.test');

    await tester.tap(find.byKey(const ValueKey('login-resend')));
    await tester.pumpAndSettle();
    expect(auth.sentTo, hasLength(2));
    expect(find.text('Ti abbiamo inviato un nuovo codice.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('login-change-email')));
    await tester.pumpAndSettle();
    final email = tester.widget<TextField>(find.byKey(const ValueKey('login-email')));
    expect(email.controller!.text, 'evelyn@example.test');
  });

  testWidgets('demasiados pedidos: lo explica', (tester) async {
    await pumpLogin(tester);
    auth.sendFailure = AuthFailureKind.rateLimited;
    await enterEmail(tester, 'evelyn@example.test');
    expect(
      find.text('Hai chiesto troppi codici. Aspetta un minuto e riprova.'),
      findsOneWidget,
    );
  });

  testWidgets('el captcha de Auth: obligatorio en producción, y el envío lleva su token', (tester) async {
    final captcha = FakeCaptchaService();
    final container = await pumpLogin(tester, captcha: captcha);
    expect(container.read(captchaRequiredProvider), isTrue);
    await enterEmail(tester, 'evelyn@example.test');
    expect(auth.sentCaptchaTokens, ['captcha-token-1']);
    expect(captcha.locales, ['it']);
    expect(find.byKey(const ValueKey('login-code')), findsOneWidget);
  });

  testWidgets('en desarrollo (sin captcha en el Supabase local) sin token el código se pide igual', (tester) async {
    await pumpLogin(
      tester,
      captcha: const NoCaptchaService(),
      overrides: [captchaRequiredProvider.overrideWithValue(false)],
    );
    await enterEmail(tester, 'evelyn@example.test');
    expect(auth.sentCaptchaTokens, [null]);
    expect(find.byKey(const ValueKey('login-code')), findsOneWidget);
  });

  testWidgets('sin token, en producción (PR11): lo explica y se reintenta con el mismo botón', (tester) async {
    final captcha = FakeCaptchaService(available: false);
    await pumpLogin(tester, captcha: captcha);
    await enterEmail(tester, 'evelyn@example.test');
    expect(find.textContaining('verifica anti-spam'), findsOneWidget);
    // El motivo (diagnóstico) va primero, en su renglón: en el teléfono nunca queda cortado.
    final error = tester.widget<TextField>(find.byKey(const ValueKey('login-email'))).decoration!.errorText!;
    expect(error.split('\n').first, '(codice: app-timeout)');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('login-email'))).decoration!.errorMaxLines, greaterThanOrEqualTo(6));
    expect(auth.sentTo, isEmpty);

    captcha.available = true;
    await tester.tap(find.byKey(const ValueKey('login-send-code')));
    await tester.pumpAndSettle();
    expect(auth.sentTo, ['evelyn@example.test']);
    expect(find.byKey(const ValueKey('login-code')), findsOneWidget);
  });

  testWidgets('en español', (tester) async {
    await pumpLogin(tester, locale: const Locale('es', 'ES'));
    expect(find.text('Envíame el código'), findsOneWidget);
    await enterEmail(tester, 'evelyn@example.test');
    expect(auth.sentLocales, ['es']);
    expect(find.text('Entrar'), findsOneWidget);
  });

  testWidgets('enlace directo a un pedido sin sesión: después del login lo abre', (
    tester,
  ) async {
    final container = await pumpLogin(tester);
    // Como el botón del email: /gestione/#/richieste/req-42
    container.read(routerProvider).go('/richieste/req-42');
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);

    await enterEmail(tester, 'evelyn@example.test');
    await tester.enterText(find.byKey(const ValueKey('login-code')), '123456');
    await tester.tap(find.byKey(const ValueKey('login-verify')));
    await tester.pumpAndSettle();

    expect(find.byType(RequestDetailScreen), findsOneWidget);
  });
}

// El acceso con contraseña de las clientas, de punta a punta en la app (repos
// falsos): /app/ en la web, la app nativa (con el «Accesso cucina») y
// «Cambia password».
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/presentation/change_password_screen.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/client/presentation/client_shell.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeLinkLauncher links;

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<ProviderContainer> pumpAccess(
    WidgetTester tester, {
    AppEntry entry = AppEntry.client,
    bool isWeb = true,
    AppUser? user,
    Account account = const Account(role: AccountRole.client),
    Locale locale = const Locale('it', 'IT'),
    List<Override> overrides = const [],
    String? initialRoute,
  }) {
    setSurfaceSize(tester, const Size(400, 1000));
    if (initialRoute != null) {
      // La ruta con que arranca la app (en la web, el fragmento de la URL).
      tester.platformDispatcher.defaultRouteNameTestValue = initialRoute;
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    }
    auth = FakeAuthRepository(user: user);
    links = FakeLinkLauncher();
    return pumpRadiciApp(
      tester,
      entry: entry,
      isWeb: isWeb,
      deviceLocales: [locale],
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(FakeAccountRepository(account)),
        linkLauncherProvider.overrideWithValue(links),
        ...overrides,
      ],
    );
  }

  Future<void> tapAndSettle(WidgetTester tester, String k) async {
    await tester.ensureVisible(key(k));
    await tester.tap(key(k));
    await tester.pumpAndSettle();
  }

  group('/app/ (web)', () {
    testWidgets('email y contraseña → el área de la clienta; sin código ni «Accesso cucina»', (tester) async {
      await pumpAccess(tester);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(key('login-send-code'), findsNothing, reason: 'en /app/ no hay código');
      expect(key('login-switch-method'), findsNothing);
      expect(find.text('Entra con la tua email e la tua password.'), findsOneWidget);

      await tester.enterText(key('access-email'), ' Cliente@Example.test ');
      await tester.enterText(key('access-password'), auth.validPassword);
      await tapAndSettle(tester, 'access-sign-in');
      expect(auth.passwordRequests, ['signIn:cliente@example.test']);
      expect(auth.passwordCaptchaTokens.single, isNotNull, reason: 'un token de captcha');
      expect(find.byType(ClientShell), findsOneWidget);
    });

    testWidgets('contraseña incorrecta: el aviso sugiere «Password dimenticata?»', (tester) async {
      await pumpAccess(tester);
      await tester.enterText(key('access-email'), 'cliente@example.test');
      await tester.enterText(key('access-password'), 'Sbagliata123');
      await tapAndSettle(tester, 'access-sign-in');
      expect(
        find.text('Email o password non corretti. Se non ricordi la password, usa «Password dimenticata?».'),
        findsOneWidget,
      );
      expect(find.byType(ClientShell), findsNothing);
    });

    testWidgets('la contraseña se oculta y se muestra con el ojo', (tester) async {
      await pumpAccess(tester);
      TextField field() => tester.widget<TextField>(key('access-password'));
      expect(field().obscureText, isTrue);
      expect(find.byTooltip('Mostra la password'), findsOneWidget);
      await tapAndSettle(tester, 'access-password-toggle');
      expect(field().obscureText, isFalse);
      expect(find.byTooltip('Nascondi la password'), findsOneWidget);
    });

    testWidgets('/accedi?email= deja el email escrito (el «Vai al login» de /accesso/)', (tester) async {
      await pumpAccess(tester, initialRoute: '/accedi?email=Cliente%40Example.test');
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(tester.widget<TextField>(key('access-email')).controller?.text, 'cliente@example.test');
    });

    testWidgets('/accedi?email= con algo que no es un email: el campo queda vacío', (tester) async {
      await pumpAccess(tester, initialRoute: '/accedi?email=%3Cscript%3E');
      expect(tester.widget<TextField>(key('access-email')).controller?.text, isEmpty);
    });

    testWidgets('en /gestione/ el código también toma el email de la ruta', (tester) async {
      await pumpAccess(tester, entry: AppEntry.kitchen, initialRoute: '/accedi?email=evelyn%40example.test');
      expect(tester.widget<TextField>(key('login-email')).controller?.text, 'evelyn@example.test');
    });

    testWidgets('«Password dimenticata?»: el email sigue escrito, el aviso no dice si hay cuenta, «Reinvia» y volver', (tester) async {
      await pumpAccess(tester);
      await tester.enterText(key('access-email'), 'cliente@example.test');
      await tapAndSettle(tester, 'access-forgot');
      expect(find.text('Scrivi la tua email: se ha un account, ti mandiamo un link per sceglierne una nuova.'), findsOneWidget);
      expect(tester.widget<TextField>(key('access-email')).controller?.text, 'cliente@example.test');

      await tapAndSettle(tester, 'access-send-reset');
      expect(auth.passwordRequests, ['reset:cliente@example.test']);
      expect(
        find.text('Fatto. Se cliente@example.test ha un account, ti arriva un link per scegliere la password.'),
        findsOneWidget,
      );

      await tapAndSettle(tester, 'access-resend');
      expect(auth.passwordRequests.last, 'reset:cliente@example.test');
      expect(key('access-resent'), findsOneWidget);
      expect(auth.passwordCaptchaTokens.toSet(), hasLength(1), reason: 'TokenCaptchaService da siempre el mismo valor');

      await tapAndSettle(tester, 'access-back');
      expect(key('access-sign-in'), findsOneWidget);
      expect(tester.widget<TextField>(key('access-email')).controller?.text, 'cliente@example.test');
    });

    testWidgets('«Crea account»: el link a la informativa debajo del botón, y el aviso con las altas cerradas', (tester) async {
      await pumpAccess(tester);
      // Ya en el acceso, debajo de «Crea account».
      expect(key('access-privacy'), findsOneWidget);
      await tapAndSettle(tester, 'access-go-sign-up');
      expect(find.text('Crea il tuo account'), findsOneWidget);
      expect(key('access-privacy'), findsOneWidget);
      await tapAndSettle(tester, 'access-privacy');
      expect(links.launched, [Uri.parse('https://radicicucina.app/privacy/?lang=it')]);
      expect(auth.passwordRequests, isEmpty, reason: 'la informativa se ve antes de mandar el email');

      auth.emailFailure = AuthFailureKind.signupClosed;
      await tester.enterText(key('access-email'), 'nueva@example.test');
      await tapAndSettle(tester, 'access-sign-up');
      expect(find.text('Le iscrizioni apriranno presto.'), findsOneWidget);
      expect(key('access-sent'), findsNothing);
    });

    testWidgets('«Crea account» con las altas abiertas: el mismo aviso exista o no la cuenta', (tester) async {
      await pumpAccess(tester, locale: const Locale('es', 'ES'));
      await tapAndSettle(tester, 'access-go-sign-up');
      await tester.enterText(key('access-email'), 'nueva@example.test');
      await tapAndSettle(tester, 'access-sign-up');
      expect(auth.passwordRequests, ['signUp:nueva@example.test']);
      expect(
        find.text(
          'Listo. Si nueva@example.test todavía no tiene cuenta, te llega un enlace para confirmarlo y elegir la contraseña. Si ya tienes cuenta, entra o usa «¿Olvidaste la contraseña?».',
        ),
        findsOneWidget,
      );
      await tapAndSettle(tester, 'access-resend');
      expect(auth.passwordRequests.last, 'resend:nueva@example.test');
    });

    testWidgets('una cuenta de la cocina con contraseña: entra solo con el código', (tester) async {
      await pumpAccess(tester);
      auth.passwordFailure = AuthFailureKind.kitchenCodeOnly;
      await tester.enterText(key('access-email'), 'evelyn@example.test');
      await tester.enterText(key('access-password'), auth.validPassword);
      await tapAndSettle(tester, 'access-sign-in');
      expect(find.text('Questo account è della cucina ed entra solo con il codice via email.'), findsOneWidget);
    });
  });

  testWidgets('/gestione/: solo el código, sin contraseña ni «Crea account»', (tester) async {
    await pumpAccess(tester, entry: AppEntry.kitchen);
    expect(key('login-send-code'), findsOneWidget);
    expect(key('access-password'), findsNothing);
    expect(key('access-go-sign-up'), findsNothing);
    expect(key('login-switch-method'), findsNothing);
  });

  testWidgets('app nativa: la contraseña primero y el «Accesso cucina» con el código, ida y vuelta', (tester) async {
    await pumpAccess(tester, entry: AppEntry.auto, isWeb: false, account: chefAccountData);
    await tapAndSettle(tester, 'home-login');
    expect(key('access-password'), findsOneWidget);
    expect(find.text('Accesso cucina: entra con un codice via email'), findsOneWidget);

    await tapAndSettle(tester, 'login-switch-method');
    expect(key('access-password'), findsNothing);
    expect(key('login-send-code'), findsOneWidget);
    await tester.enterText(key('login-email'), 'evelyn@example.test');
    await tapAndSettle(tester, 'login-send-code');
    expect(auth.sentTo, ['evelyn@example.test']);

    await tapAndSettle(tester, 'login-switch-method');
    expect(key('access-password'), findsOneWidget);
    expect(find.text('Entra con email e password'), findsNothing);
  });

  group('«Cambia password»', () {
    const user = AppUser(id: 'client-1', email: 'cliente@example.test');

    Future<void> openScreen(WidgetTester tester) async {
      await pumpAccess(tester, user: user);
      expect(find.byType(ClientShell), findsOneWidget);
      await tapAndSettle(tester, 'client-area-change-password');
      expect(find.byType(ChangePasswordScreen), findsOneWidget);
    }

    testWidgets('con la actual y la nueva: guarda, avisa y vuelve al área', (tester) async {
      await openScreen(tester);
      expect(find.text('Almeno 10 caratteri, con lettere e numeri.'), findsOneWidget);
      await tester.enterText(key('change-password-current'), 'Vecchia1234');
      await tester.enterText(key('change-password-new'), 'Nuova123456');
      await tester.enterText(key('change-password-repeat'), 'Nuova123465');
      await tapAndSettle(tester, 'change-password-save');
      expect(find.text('Le due password non coincidono: scrivile di nuovo.'), findsOneWidget);
      expect(auth.passwordChanges, isEmpty);

      await tester.enterText(key('change-password-repeat'), 'Nuova123456');
      await tapAndSettle(tester, 'change-password-save');
      expect(auth.passwordChanges, [('Vecchia1234', 'Nuova123456')]);
      expect(find.text('Password aggiornata. Le altre sessioni aperte sono state chiuse.'), findsOneWidget);
      expect(find.byType(ClientShell), findsOneWidget);
      expect(find.byType(ChangePasswordScreen), findsNothing);
    });

    testWidgets('la regla se avisa en la nueva y la actual incorrecta en la actual', (tester) async {
      await openScreen(tester);
      await tester.enterText(key('change-password-current'), 'Vecchia1234');
      await tester.enterText(key('change-password-new'), 'corta1');
      await tapAndSettle(tester, 'change-password-save');
      expect(find.text('La password deve avere almeno 10 caratteri.'), findsOneWidget);
      expect(auth.passwordChanges, isEmpty);

      auth.changeFailure = AuthFailureKind.wrongCurrentPassword;
      await tester.enterText(key('change-password-new'), 'Nuova123456');
      await tester.enterText(key('change-password-repeat'), 'Nuova123456');
      await tapAndSettle(tester, 'change-password-save');
      expect(find.text('La password attuale non è corretta.'), findsOneWidget);
      expect(find.byType(ChangePasswordScreen), findsOneWidget);

      auth.changeFailure = AuthFailureKind.network;
      await tapAndSettle(tester, 'change-password-save');
      expect(key('change-password-error'), findsOneWidget);
    });
  });
}

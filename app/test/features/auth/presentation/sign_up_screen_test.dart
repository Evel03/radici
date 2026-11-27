// «Crear cuenta» en la app completa (/app/ y la app nativa): los datos, la contraseña dos veces, el código del email y
// el área, sin pasar por ningún link.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';
import 'package:radici/features/auth/presentation/sign_up_screen.dart';
import 'package:radici/features/client/presentation/client_shell.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeAccountRepository accounts;
  late FakeLinkLauncher links;

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> pumpSignUp(
    WidgetTester tester, {
    AppEntry entry = AppEntry.client,
    bool isWeb = true,
    Locale locale = const Locale('es', 'ES'),
  }) async {
    setSurfaceSize(tester, const Size(420, 1400));
    tester.platformDispatcher.defaultRouteNameTestValue = '/crea-account';
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    auth = FakeAuthRepository();
    accounts = FakeAccountRepository(const Account(role: AccountRole.client));
    links = FakeLinkLauncher();
    await pumpRadiciApp(
      tester,
      entry: entry,
      isWeb: isWeb,
      deviceLocales: [locale],
      clock: () => DateTime.utc(2026, 11, 27, 10),
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(accounts),
        linkLauncherProvider.overrideWithValue(links),
      ],
    );
  }

  Future<void> tapAndSettle(WidgetTester tester, String k) async {
    await tester.ensureVisible(key(k));
    await tester.tap(key(k));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String k, String text) async {
    await tester.ensureVisible(key(k));
    await tester.enterText(key(k), text);
  }

  testWidgets(
    'datos → código → contraseña y datos guardados → el área, sin ningún link',
    (tester) async {
      await pumpSignUp(tester);
      expect(find.byType(SignUpScreen), findsOneWidget);
      expect(find.text('Crea tu cuenta'), findsOneWidget);

      await type(tester, 'signup-first-name', 'Anna');
      await type(tester, 'signup-last-name', 'Rota');
      await type(tester, 'signup-phone', '340 123 4567');
      await type(tester, 'signup-birth-date', '17/05/1990');
      await type(tester, 'signup-email', 'Anna@Example.com');
      await type(tester, 'signup-password', 'Bergamo2027');
      await type(tester, 'signup-repeat', 'Bergamo2027');
      await type(tester, 'signup-street', 'Via Pignolo 12');
      await type(tester, 'signup-city', 'Bergamo');
      await type(tester, 'signup-postal', '24121');
      // Después de escribir, el campo enfocado vuelve a mostrar el cursor en el cuadro siguiente: en el test, antes de
      // tocar los chips, se suelta el foco (una persona no escribe y toca en el mismo instante).
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tapAndSettle(tester, 'signup-season-autumn');
      await tapAndSettle(tester, 'signup-heard-instagram');
      await tapAndSettle(tester, 'signup-interest-weekly');
      await tapAndSettle(tester, 'signup-interest-dinners');
      await tapAndSettle(tester, 'signup-day-2');
      await tapAndSettle(tester, 'signup-household-threeFour');
      expect(
        find.text('Martes'),
        findsOneWidget,
        reason: 'los días en el idioma de la app',
      );
      await tapAndSettle(tester, 'signup-privacy');
      await tapAndSettle(tester, 'signup-submit');

      expect(auth.passwordRequests, ['signUp:anna@example.com']);
      expect(find.text('Confirma tu email'), findsOneWidget);
      expect(
        find.textContaining(
          'Si anna@example.com no tenía cuenta, te mandamos un código de 10 cifras',
        ),
        findsOneWidget,
      );
      expect(
        auth.newPasswords,
        isEmpty,
        reason: 'la contraseña se pone recién con el código',
      );

      await type(tester, 'signup-code', '1234567890');
      await tapAndSettle(tester, 'signup-code-confirm');

      expect(auth.newPasswords, ['Bergamo2027']);
      expect(accounts.savedDetails.single, {
        'first_name': 'Anna',
        'last_name': 'Rota',
        'phone': '+393401234567',
        'birth_date': '1990-05-17',
        'address_street': 'Via Pignolo 12',
        'address_city': 'Bergamo',
        'address_postal_code': '24121',
        'address_notes': null,
        'favorite_season': 'autumn',
        'heard_from': 'instagram',
        'interests': ['weekly', 'dinners'],
        'preferred_days': [2],
        'household_size': '3-4',
        'privacy_version': accountPrivacyVersion,
      });
      expect(
        find.byType(ClientShell),
        findsOneWidget,
        reason: 'termina en su área',
      );
      expect(find.text('Tu cuenta está lista.'), findsOneWidget);
      expect(links.pages, isEmpty, reason: 'ningún link: todo en la app');
    },
  );

  testWidgets('sin completar: cada campo dice qué falta y no se manda nada', (
    tester,
  ) async {
    await pumpSignUp(tester);
    await type(tester, 'signup-birth-date', '28/11/2008');
    await type(tester, 'signup-password', 'Bergamo2027');
    await type(tester, 'signup-repeat', 'Bergamo2072');
    await type(tester, 'signup-city', 'Bergamo');
    await tapAndSettle(tester, 'signup-submit');
    expect(auth.passwordRequests, isEmpty);
    expect(find.text('Revisa los campos marcados.'), findsOneWidget);
    expect(find.text('Este dato es obligatorio.'), findsNWidgets(2));
    expect(
      find.text('Para crear una cuenta tienes que tener al menos 18 años.'),
      findsOneWidget,
    );
    expect(
      find.text('Las dos contraseñas no coinciden: escríbelas de nuevo.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Completa la dirección (calle, ciudad y código postal) o déjala vacía.',
      ),
      findsNWidgets(2),
    );
    expect(
      find.text(
        'Para crear la cuenta tienes que aceptar la política de privacidad.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'el código equivocado avisa; «Cambiar mis datos» vuelve con todo escrito',
    (tester) async {
      await pumpSignUp(tester, locale: const Locale('it', 'IT'));
      await type(tester, 'signup-first-name', 'Anna');
      await type(tester, 'signup-last-name', 'Rota');
      await type(tester, 'signup-phone', '3401234567');
      await type(tester, 'signup-birth-date', '1990-05-17');
      await type(tester, 'signup-email', 'anna@example.com');
      await type(tester, 'signup-password', 'Bergamo2027');
      await type(tester, 'signup-repeat', 'Bergamo2027');
      await tapAndSettle(tester, 'signup-privacy');
      await tapAndSettle(tester, 'signup-submit');

      await type(tester, 'signup-code', '9999999999');
      await tapAndSettle(tester, 'signup-code-confirm');
      expect(key('signup-error'), findsOneWidget);
      expect(find.byType(SignUpScreen), findsOneWidget);

      await tapAndSettle(tester, 'signup-edit');
      expect(
        tester.widget<TextField>(key('signup-first-name')).controller?.text,
        'Anna',
      );
      expect(
        tester.widget<TextField>(key('signup-email')).controller?.text,
        'anna@example.com',
      );
    },
  );

  testWidgets(
    'el link a la informativa se abre dentro de la app, en su idioma',
    (tester) async {
      await pumpSignUp(tester, locale: const Locale('en', 'GB'));
      await tapAndSettle(tester, 'signup-privacy-link');
      expect(links.pages, [
        Uri.parse('https://radicicucina.app/privacy/?lang=en'),
      ]);
    },
  );

  testWidgets('en /gestione/ no existe: va al login de la cocina', (
    tester,
  ) async {
    await pumpSignUp(tester, entry: AppEntry.kitchen);
    expect(find.byType(SignUpScreen), findsNothing);
  });
}

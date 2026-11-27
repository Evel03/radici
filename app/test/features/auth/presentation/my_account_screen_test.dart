// «Mi cuenta» en el área de la clienta (auth.md §20): ver y corregir los datos, borrar las respuestas opcionales y
// borrar la cuenta.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';
import 'package:radici/features/auth/presentation/my_account_screen.dart';
import 'package:radici/features/client/presentation/client_shell.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';

const Map<String, Object?> _saved = {
  'first_name': 'Anna',
  'last_name': 'Rota',
  'phone': '+393401234567',
  'birth_date': '1990-05-17',
  'address_street': 'Via Pignolo 12',
  'address_city': 'Bergamo',
  'address_postal_code': '24121',
  'address_notes': null,
  'favorite_season': 'winter',
  'heard_from': 'instagram',
  'interests': ['weekly'],
  'preferred_days': [1, 3],
  'household_size': '3-4',
  'privacy_version': accountPrivacyVersion,
};

void main() {
  late FakeAuthRepository auth;
  late FakeAccountRepository accounts;

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> openAccount(WidgetTester tester, {Map<String, Object?>? saved = _saved, bool fromArea = false}) async {
    setSurfaceSize(tester, const Size(420, 1600));
    if (!fromArea) {
      tester.platformDispatcher.defaultRouteNameTestValue = '/area/account';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    }
    auth = FakeAuthRepository(user: const AppUser(id: 'client-1', email: 'anna@example.test'));
    accounts = FakeAccountRepository(const Account(role: AccountRole.client))..storedDetails = saved;
    await pumpRadiciApp(
      tester,
      entry: AppEntry.client,
      isWeb: true,
      deviceLocales: const [Locale('es', 'ES')],
      clock: () => DateTime.utc(2026, 11, 27, 10),
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(accounts),
        linkLauncherProvider.overrideWithValue(FakeLinkLauncher()),
      ],
    );
  }

  Future<void> tapAndSettle(WidgetTester tester, String k) async {
    await tester.ensureVisible(key(k));
    await tester.tap(key(k));
    await tester.pumpAndSettle();
  }

  String textOf(WidgetTester tester, String k) => tester.widget<TextField>(key(k)).controller!.text;

  testWidgets('se abre desde el área con los datos guardados escritos', (tester) async {
    await openAccount(tester, fromArea: true);
    expect(find.byType(ClientShell), findsOneWidget);
    await tapAndSettle(tester, 'client-area-account');
    expect(find.byType(MyAccountScreen), findsOneWidget);
    expect(find.text('Mi cuenta'), findsOneWidget);

    expect(find.text('anna@example.test'), findsOneWidget);
    expect(textOf(tester, 'signup-first-name'), 'Anna');
    expect(textOf(tester, 'signup-phone'), '+393401234567');
    expect(textOf(tester, 'signup-birth-date'), '17/05/1990');
    expect(textOf(tester, 'signup-postal'), '24121');
    expect(tester.widget<ChoiceChip>(key('signup-season-winter')).selected, isTrue);
    expect(tester.widget<FilterChip>(key('signup-day-3')).selected, isTrue);
    expect(tester.widget<ChoiceChip>(key('signup-household-threeFour')).selected, isTrue);
    // La privacy ya está aceptada con esta versión: no se pide otra vez. Ni email ni contraseña para cambiar.
    expect(key('my-account-privacy'), findsNothing);
    expect(key('signup-email'), findsNothing);
    expect(key('signup-password'), findsNothing);
  });

  testWidgets('corregir un dato y guardar', (tester) async {
    await openAccount(tester);
    await tester.enterText(key('signup-phone'), '12');
    await tapAndSettle(tester, 'my-account-save');
    expect(find.text('Revisa los campos marcados.'), findsOneWidget);
    expect(accounts.savedDetails, isEmpty);

    await tester.enterText(key('signup-phone'), '348 765 4321');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tapAndSettle(tester, 'signup-season-summer');
    await tapAndSettle(tester, 'my-account-save');
    expect(accounts.savedDetails.single, containsPair('phone', '+393487654321'));
    expect(accounts.savedDetails.single, containsPair('favorite_season', 'summer'));
    expect(accounts.savedDetails.single, containsPair('address_city', 'Bergamo'));
    expect(key('my-account-saved'), findsOneWidget);
    // Vuelve a leer lo guardado: el teléfono queda con el prefijo.
    expect(textOf(tester, 'signup-phone'), '+393487654321');
  });

  testWidgets('sin datos guardados: lo avisa y pide la privacy', (tester) async {
    await openAccount(tester, saved: null);
    expect(key('my-account-empty'), findsOneWidget);
    expect(key('my-account-clear-optional'), findsNothing);
    await tester.enterText(key('signup-first-name'), 'Anna');
    await tester.enterText(key('signup-last-name'), 'Rota');
    await tester.enterText(key('signup-phone'), '3401234567');
    await tester.enterText(key('signup-birth-date'), '17/05/1990');
    await tapAndSettle(tester, 'my-account-save');
    expect(find.text('Para guardar tus datos tienes que aceptar la política de privacidad.'), findsOneWidget);
    expect(accounts.savedDetails, isEmpty);
    expect(find.text('Revisa los campos marcados.'), findsOneWidget);

    await tapAndSettle(tester, 'my-account-privacy');
    await tapAndSettle(tester, 'my-account-save');
    expect(accounts.savedDetails.single, containsPair('first_name', 'Anna'));
    expect(key('my-account-empty'), findsNothing);
  });

  testWidgets('borrar las respuestas opcionales: pide confirmar y guarda sin ellas', (tester) async {
    await openAccount(tester);
    await tapAndSettle(tester, 'my-account-clear-optional');
    expect(find.text('¿Borrar tus respuestas opcionales?'), findsOneWidget);
    await tapAndSettle(tester, 'my-account-clear-confirm');
    final saved = accounts.savedDetails.single;
    for (final field in ['favorite_season', 'heard_from', 'interests', 'preferred_days', 'household_size']) {
      expect(saved[field], isNull, reason: field);
    }
    expect(saved, containsPair('address_street', 'Via Pignolo 12'));
    expect(tester.widget<ChoiceChip>(key('signup-season-winter')).selected, isFalse);
  });

  testWidgets('borrar la cuenta: «Cancelar» no hace nada; confirmar la borra y sale', (tester) async {
    await openAccount(tester);
    await tapAndSettle(tester, 'my-account-delete');
    expect(find.text('¿Borrar tu cuenta?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(accounts.deletes, 0);
    expect(find.byType(MyAccountScreen), findsOneWidget);

    await tapAndSettle(tester, 'my-account-delete');
    await tapAndSettle(tester, 'my-account-delete-confirm');
    expect(accounts.deletes, 1);
    expect(auth.user, isNull);
    expect(find.byType(MyAccountScreen), findsNothing);
    expect(find.byType(ClientShell), findsNothing);
    expect(find.text('Tu cuenta se borró.'), findsOneWidget);
  });

  testWidgets('si no se pudo borrar, lo dice y sigue en «Mi cuenta»', (tester) async {
    await openAccount(tester);
    accounts.deleteFailure = const AccountFailure(AccountFailureKind.unavailable);
    await tapAndSettle(tester, 'my-account-delete');
    await tapAndSettle(tester, 'my-account-delete-confirm');
    expect(key('my-account-error'), findsOneWidget);
    expect(find.byType(MyAccountScreen), findsOneWidget);
    expect(auth.user, isNotNull);
  });

  testWidgets('si no se pudieron leer los datos: «Reintentar»', (tester) async {
    setSurfaceSize(tester, const Size(420, 1600));
    tester.platformDispatcher.defaultRouteNameTestValue = '/area/account';
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    auth = FakeAuthRepository(user: const AppUser(id: 'client-1', email: 'anna@example.test'));
    accounts = FakeAccountRepository(const Account(role: AccountRole.client))
      ..storedDetails = _saved
      ..fetchDetailsFailure = const AccountFailure(AccountFailureKind.unavailable);
    await pumpRadiciApp(
      tester,
      entry: AppEntry.client,
      isWeb: true,
      deviceLocales: const [Locale('es', 'ES')],
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(accounts),
      ],
    );
    expect(key('my-account-load-error'), findsOneWidget);
    accounts.fetchDetailsFailure = null;
    await tapAndSettle(tester, 'my-account-retry');
    expect(textOf(tester, 'signup-first-name'), 'Anna');
  });
}

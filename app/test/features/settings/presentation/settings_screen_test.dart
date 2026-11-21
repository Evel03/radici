// Idioma de Evelyn de punta a punta: el perfil manda sobre el dispositivo, se
// cambia en Impostazioni, queda guardado para el arranque en frío y al salir
// vuelve el del dispositivo.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/auth/presentation/session_screen.dart';
import 'package:radici/features/more/presentation/more_screen.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/settings/data/language_cache.dart';
import 'package:radici/features/settings/presentation/settings_screen.dart';
import 'package:radici/features/today/presentation/today_screen.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late MemoryLanguageCache cache;

  FakeAccountRepository profileIn(AppLanguage language) =>
      FakeAccountRepository(chefAccountData.copyWith(language: language));

  Future<ChefApp> openApp(
    WidgetTester tester, {
    AppLanguage profile = AppLanguage.es,
    Locale device = const Locale('it', 'IT'),
    String? location,
  }) => pumpChefApp(
    tester,
    requests: FakeChefRequestsRepository([buildRequest()]),
    accounts: profileIn(profile),
    deviceLocales: [device],
    location: location,
    overrides: [languageCacheProvider.overrideWithValue(cache)],
  );

  /// En el teléfono, Impostazioni está en la pestaña «Altro» (la cuarta).
  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('more-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  }

  setUp(() => cache = MemoryLanguageCache());

  testWidgets('perfil en español: la interfaz sale en español aunque el '
      'dispositivo esté en italiano', (tester) async {
    await openApp(tester);
    expect(find.byType(TodayScreen), findsOneWidget);
    expect(find.text('Hoy'), findsWidgets);
    expect(find.text('Solicitudes'), findsWidgets);
    expect(find.text('Richieste'), findsNothing);
    expect(cache.read(), (userId: chefUser.id, language: AppLanguage.es));
  });

  testWidgets(
    'Impostazioni: cambiar a italiano cambia la interfaz y lo guarda',
    (tester) async {
      final app = await openApp(tester);
      await openSettings(tester);
      expect(find.text('Ajustes'), findsOneWidget);
      // Opciones en su propio idioma, con el actual marcado.
      expect(find.text('Español'), findsOneWidget);
      expect(find.text('Italiano'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('language-es'))),
        isSemantics(isChecked: true),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('language-it'))),
        isSemantics(isChecked: false),
      );

      await tester.tap(find.byKey(const ValueKey('language-it')));
      await tester.pumpAndSettle();

      expect(find.text('Impostazioni'), findsOneWidget);
      expect(find.text("Lingua dell'app"), findsOneWidget);
      // Guardado en el perfil (vale en todos sus dispositivos) y en este.
      expect(app.accounts.savedLanguages, [
        (userId: chefUser.id, language: AppLanguage.it),
      ]);
      expect(cache.read(), (userId: chefUser.id, language: AppLanguage.it));

      // Volver: «Altro» y la bandeja ya están en italiano.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(MoreScreen), findsOneWidget);
      expect(find.text('Altro'), findsWidgets);
      await tester.tap(find.byType(NavigationDestination).at(1));
      await tester.pumpAndSettle();
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(find.text('Richieste'), findsWidgets);
    },
  );

  testWidgets('si no se puede guardar: avisa y se queda en español', (
    tester,
  ) async {
    final app = await openApp(tester);
    app.accounts.updateFailure = AccountFailureKind.unavailable;
    await openSettings(tester);

    await tester.tap(find.byKey(const ValueKey('language-en')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'No se pudo cambiar el idioma. Revisa la conexión y vuelve a intentarlo.',
      ),
      findsOneWidget,
    );
    expect(find.text('Ajustes'), findsOneWidget);
    expect(cache.read(), (userId: chefUser.id, language: AppLanguage.es));
  });

  testWidgets('salir desde Impostazioni: el login vuelve al idioma del '
      'dispositivo y se borra lo guardado', (tester) async {
    final app = await openApp(tester, device: const Locale('en', 'GB'));
    await openSettings(tester);
    await tester.tap(find.byKey(const ValueKey('settings-logout')));
    await tester.pumpAndSettle();

    expect(app.auth.user, isNull);
    // Como al salir desde la bandeja: al login, en el idioma del dispositivo.
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Send me the code'), findsOneWidget);
    expect(cache.read(), isNull);
  });

  testWidgets('enlace directo a Impostazioni: la cruz lleva a Hoy, el inicio', (
    tester,
  ) async {
    await openApp(tester, location: '/impostazioni');
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
    expect(find.byType(TodayScreen), findsOneWidget);
  });

  testWidgets('arranque en frío: con el idioma guardado la app arranca ya en '
      'ese idioma, antes de leer el perfil', (tester) async {
    // Lo guardó una sesión anterior en este dispositivo (SharedPreferences).
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await (await SharedPreferencesLanguageCache.load()).write((
      userId: chefUser.id,
      language: AppLanguage.it,
    ));

    // Nuevo arranque: dispositivo en español y el perfil todavía cargando.
    final accounts = profileIn(AppLanguage.it)
      ..pendingFetch = Completer<void>();
    await pumpRadiciApp(
      tester,
      deviceLocales: const [Locale('es', 'ES')],
      settle: false,
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: chefUser),
        ),
        accountRepositoryProvider.overrideWithValue(accounts),
        chefRequestsRepositoryProvider.overrideWithValue(
          FakeChefRequestsRepository([buildRequest()]),
        ),
        languageCacheProvider.overrideWithValue(
          await SharedPreferencesLanguageCache.load(),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(find.text('Un attimo…'), findsOneWidget);
    expect(find.text('Un momento…'), findsNothing);

    // El perfil lo confirma: sigue en italiano.
    accounts.pendingFetch!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TodayScreen), findsOneWidget);
    expect(find.text('Richieste'), findsWidgets);
  });

  testWidgets('sin sesión, el login sigue al dispositivo', (tester) async {
    await pumpRadiciApp(
      tester,
      isWeb: true,
      deviceLocales: const [Locale('es', 'AR')],
      overrides: [languageCacheProvider.overrideWithValue(cache)],
    );
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Envíame el código'), findsOneWidget);
  });

  testWidgets('la cocinera ve su nombre en la cuenta', (tester) async {
    await openApp(tester, location: '/impostazioni');
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Evelyn'), findsOneWidget);
    expect(find.textContaining('Colaborador'), findsNothing);
    expect(find.text('Iniciaste sesión como ${chefUser.email}'), findsOneWidget);
  });

  testWidgets('un colaborador ve «Colaborador de Evelyn» y con qué email '
      'entró', (tester) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      accounts: FakeAccountRepository(
        chefAccountData.copyWith(
          chef: chefAccount.copyWith(collaborator: true),
          language: AppLanguage.es,
        ),
      ),
      location: '/impostazioni',
      overrides: [languageCacheProvider.overrideWithValue(cache)],
    );
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Colaborador de Evelyn'), findsOneWidget);
    expect(find.text('Iniciaste sesión como ${chefUser.email}'), findsOneWidget);
  });

  // El menú de la cuenta dice lo mismo que Impostazioni. A 1200×800, como
  // /gestione/ en una computadora, que es donde siempre está el menú.
  for (final collaborator in [false, true]) {
    testWidgets(
      'menú de la cuenta: '
      '${collaborator ? '«Colaborador de Evelyn»' : 'el nombre de la cocinera'}'
      ' y con qué email entró',
      (tester) async {
        await pumpChefApp(
          tester,
          requests: FakeChefRequestsRepository(const []),
          accounts: FakeAccountRepository(
            chefAccountData.copyWith(
              chef: chefAccount.copyWith(collaborator: collaborator),
              language: AppLanguage.es,
            ),
          ),
          size: const Size(1200, 800),
          overrides: [languageCacheProvider.overrideWithValue(cache)],
        );
        await tester.tap(find.byKey(const ValueKey('account-menu')));
        await tester.pumpAndSettle();

        expect(
          find.widgetWithText(
            ListTile,
            collaborator ? 'Colaborador de Evelyn' : 'Evelyn',
          ),
          findsOneWidget,
        );
        if (!collaborator) {
          expect(find.textContaining('Colaborador'), findsNothing);
        }
        expect(
          find.text('Iniciaste sesión como ${chefUser.email}'),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('Impostazioni dice la versión de /gestione/ (el id del build)', (
    tester,
  ) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      accounts: profileIn(AppLanguage.es),
      location: '/impostazioni',
      overrides: [
        languageCacheProvider.overrideWithValue(cache),
        buildIdProvider.overrideWithValue('abc1234'),
      ],
    );
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Versión abc1234'), findsOneWidget);
  });

  testWidgets('sin id del build (flutter run, iOS y Android): no dice versión', (
    tester,
  ) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      accounts: profileIn(AppLanguage.es),
      location: '/impostazioni',
      overrides: [languageCacheProvider.overrideWithValue(cache)],
    );
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.textContaining('Versión'), findsNothing);
  });

  for (final language in AppLanguage.values) {
    for (final collaborator in [false, true]) {
      testWidgets(
        'Impostazioni sin desbordes en un teléfono angosto (${language.code}'
        '${collaborator ? ', colaborador' : ''})',
        (tester) async {
          await pumpChefApp(
            tester,
            requests: FakeChefRequestsRepository(const []),
            accounts: FakeAccountRepository(
              chefAccountData.copyWith(
                chef: chefAccount.copyWith(collaborator: collaborator),
                language: language,
              ),
            ),
            location: '/impostazioni',
            size: const Size(320, 640),
            overrides: [languageCacheProvider.overrideWithValue(cache)],
          );
          expect(find.byType(SettingsScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

// Pestaña «Altro» (Más) de la cocinera: en el teléfono es el tercer destino
// de la barra y reemplaza al menú de la cuenta de arriba; en pantallas anchas
// va en el riel. Tiene Piatti, Impostazioni (idioma) y Esci.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/more/presentation/more_screen.dart';
import 'package:radici/features/recipes/presentation/recipes_screen.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/settings/presentation/settings_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));

  Future<ChefApp> openApp(
    WidgetTester tester, {
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
  }) => pumpChefApp(
    tester,
    requests: FakeChefRequestsRepository([buildRequest()]),
    recipes: FakeRecipesRepository(sampleRecipes()),
    size: size,
    deviceLocales: [locale],
  );

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(
      find.descendant(of: byKey('chef-nav-bar'), matching: find.text('Altro')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MoreScreen), findsOneWidget);
  }

  group('teléfono', () {
    testWidgets('tres destinos en la barra y sin menú de la cuenta arriba', (tester) async {
      await openApp(tester);
      final bar = tester.widget<NavigationBar>(byKey('chef-nav-bar'));
      expect(bar.destinations, hasLength(3));
      expect(
        find.descendant(of: byKey('chef-nav-bar'), matching: find.text('Altro')),
        findsOneWidget,
      );
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(byKey('account-menu'), findsNothing);

      await tester.tap(find.descendant(of: byKey('chef-nav-bar'), matching: find.text('Agenda')));
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(byKey('account-menu'), findsNothing);
    });

    testWidgets('«Altro»: la cuenta, Piatti, Impostazioni y Esci', (tester) async {
      await openApp(tester);
      await openMore(tester);

      expect(find.text('Evelyn'), findsOneWidget);
      expect(find.text("Hai effettuato l'accesso come evelyn@example.test"), findsOneWidget);
      expect(byKey('more-recipes'), findsOneWidget);
      expect(find.text('Piatti'), findsOneWidget);
      expect(find.text('Allergeni, stagione e ingredienti'), findsOneWidget);
      expect(byKey('more-settings'), findsOneWidget);
      expect(find.text('Impostazioni'), findsOneWidget);
      expect(byKey('more-logout'), findsOneWidget);
      expect(find.text('Esci'), findsOneWidget);
      for (final key in ['more-recipes', 'more-settings', 'more-logout']) {
        expect(tester.getSize(byKey(key)).height, greaterThanOrEqualTo(48), reason: key);
      }
    });

    testWidgets('«Altro» de un colaborador: «Collaboratore di Evelyn», como en '
        'Impostazioni', (tester) async {
      await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
        recipes: FakeRecipesRepository(sampleRecipes()),
        accounts: FakeAccountRepository(
          chefAccountData.copyWith(
            chef: chefAccount.copyWith(collaborator: true),
          ),
        ),
      );
      await openMore(tester);

      expect(find.text('Collaboratore di Evelyn'), findsOneWidget);
      expect(find.text('Evelyn'), findsNothing);
      expect(find.text("Hai effettuato l'accesso come evelyn@example.test"), findsOneWidget);
    });

    testWidgets('Piatti abre el catálogo y volver lleva a «Altro»', (tester) async {
      await openApp(tester);
      await openMore(tester);
      await tester.tap(byKey('more-recipes'));
      await tester.pumpAndSettle();
      expect(find.byType(RecipesScreen), findsOneWidget);
      // La barra sigue a la vista, con «Altro» elegido.
      expect(tester.widget<NavigationBar>(byKey('chef-nav-bar')).selectedIndex, 2);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(MoreScreen), findsOneWidget);
    });

    testWidgets('tocar «Altro» desde el catálogo vuelve al principio de la pestaña', (tester) async {
      await openApp(tester);
      await openMore(tester);
      await tester.tap(byKey('more-recipes'));
      await tester.pumpAndSettle();

      await openMore(tester);
      expect(find.byType(RecipesScreen), findsNothing);
    });

    testWidgets('Impostazioni se abre encima y vuelve a «Altro»', (tester) async {
      await openApp(tester);
      await openMore(tester);
      await tester.tap(byKey('more-settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(MoreScreen), findsOneWidget);
    });

    testWidgets('Esci cierra la sesión y lleva al login', (tester) async {
      final app = await openApp(tester);
      await openMore(tester);
      await tester.tap(byKey('more-logout'));
      await tester.pumpAndSettle();
      expect(app.auth.user, isNull);
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('en español: «Más», «Platos», «Ajustes» y «Cerrar sesión»', (tester) async {
      await openApp(tester, locale: const Locale('es', 'ES'));
      await tester.tap(find.descendant(of: byKey('chef-nav-bar'), matching: find.text('Más')));
      await tester.pumpAndSettle();
      expect(find.text('Platos'), findsOneWidget);
      expect(find.text('Ajustes'), findsOneWidget);
      expect(find.text('Cerrar sesión'), findsOneWidget);
    });

    for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
      testWidgets('a 375×667 sin desbordes (${locale.languageCode})', (tester) async {
        await openApp(tester, size: const Size(375, 667), locale: locale);
        final more = switch (locale.languageCode) {
          'es' => 'Más',
          'en' => 'More',
          _ => 'Altro',
        };
        await tester.tap(find.descendant(of: byKey('chef-nav-bar'), matching: find.text(more)));
        await tester.pumpAndSettle();
        expect(find.byType(MoreScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('pantalla ancha', () {
    testWidgets('«Altro» en el riel; arriba sigue el menú de la cuenta', (tester) async {
      await openApp(tester, size: const Size(1200, 800));
      final rail = tester.widget<NavigationRail>(byKey('chef-nav-rail'));
      expect(rail.destinations, hasLength(3));
      expect(byKey('account-menu'), findsOneWidget);

      await tester.tap(find.descendant(of: byKey('chef-nav-rail'), matching: find.text('Altro')));
      await tester.pumpAndSettle();
      expect(find.byType(MoreScreen), findsOneWidget);
      await tester.tap(byKey('more-recipes'));
      await tester.pumpAndSettle();
      expect(find.byType(RecipesScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // /gestione/ en una computadora: el menú de la cuenta sigue siendo un camino.
    testWidgets('el menú de la cuenta abre Impostazioni', (tester) async {
      await openApp(tester, size: const Size(1200, 800));
      await tester.tap(byKey('account-menu'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('account-settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('y «Esci» del menú de la cuenta cierra la sesión y lleva al login', (tester) async {
      final app = await openApp(tester, size: const Size(1200, 800));
      await tester.tap(byKey('account-menu'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('account-logout'));
      await tester.pumpAndSettle();
      expect(app.auth.user, isNull);
      expect(find.byType(LoginScreen), findsOneWidget);
    });
  });
}

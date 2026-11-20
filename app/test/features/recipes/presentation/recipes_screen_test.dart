// Lista de platos: el estado vacío que propone cargar el primero, cada plato
// con sus alérgenos, dieta y temporada a la vista, los desactivados al final,
// la búsqueda en los tres idiomas y el aviso al volver del editor.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/more/presentation/more_screen.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:radici/features/recipes/presentation/recipes_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/text_input_guard.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));
  Finder tile(String id) => byKey('recipe-$id');
  Finder inTile(String id, String text) =>
      find.descendant(of: tile(id), matching: find.text(text));

  Future<ChefApp> openList(
    WidgetTester tester, {
    List<Recipe>? recipes,
    FakeRecipesRepository? repository,
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      recipes: repository ?? FakeRecipesRepository(recipes ?? sampleRecipes()),
      location: '/altro/piatti',
      size: size,
      deviceLocales: [locale],
    );
    expect(find.byType(RecipesScreen), findsOneWidget);
    return app;
  }

  testWidgets('catálogo vacío: propone cargar el primero y «Nuovo piatto» queda en el tercio inferior a 375×667', (
    tester,
  ) async {
    await openList(tester, recipes: const [], size: const Size(375, 667));

    expect(
      find.text(
        'Non hai ancora piatti. Aggiungi il primo con «Nuovo piatto»: bastano il nome in italiano e gli allergeni.',
      ),
      findsOneWidget,
    );
    final fab = byKey('recipes-new');
    expect(tester.getCenter(fab).dy, greaterThan(667 * 2 / 3));
    expect(tester.getSize(fab).height, greaterThanOrEqualTo(48));

    await tester.tap(fab);
    await tester.pumpAndSettle();
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Nuovo piatto'), findsOneWidget);
  });

  testWidgets('cada plato con alérgenos, dieta y temporada; activos por nombre y desactivados al final', (
    tester,
  ) async {
    await openList(tester);

    expect(inTile(lasagneId, 'Lasagne alla bolognese'), findsOneWidget);
    expect(inTile(lasagneId, 'Glutine · Uova · Latte e derivati · Sedano'), findsOneWidget);
    expect(inTile(lasagneId, "Tutto l'anno"), findsOneWidget);
    expect(inTile(risottoId, 'Latte e derivati · Sedano · Solfiti'), findsOneWidget);
    expect(inTile(risottoId, 'Vegetariana · set–nov'), findsOneWidget);
    expect(inTile(minestroneId, 'Vegana · ott–apr'), findsOneWidget);
    expect(inTile(frittataId, 'Disattivato'), findsOneWidget);
    // En italiano no se repite el nombre: ya es el del título.
    expect(find.text('Lasaña a la boloñesa'), findsNothing);

    double top(Finder finder) => tester.getTopLeft(finder).dy;
    expect(top(tile(lasagneId)), lessThan(top(tile(minestroneId))));
    expect(top(tile(minestroneId)), lessThan(top(tile(risottoId))));
    expect(top(tile(risottoId)), lessThan(top(find.text('Disattivati (1)'))));
    expect(top(find.text('Disattivati (1)')), lessThan(top(tile(frittataId))));
  });

  testWidgets('cada plato activo dice si está en la web o si le falta la descripción', (tester) async {
    await openList(tester);

    expect(inTile(lasagneId, 'Sul sito'), findsOneWidget);
    expect(inTile(risottoId, 'Sul sito'), findsOneWidget);
    expect(inTile(minestroneId, 'Senza descrizione: non è sul sito'), findsOneWidget);
    expect(inTile(minestroneId, 'Sul sito'), findsNothing);
    // Desactivado: ya dice «Disattivato» (no sale en la web aunque tenga
    // descripción).
    expect(byKey('recipe-web-$frittataId'), findsNothing);
    expect(inTile(frittataId, 'Sul sito'), findsNothing);
  });

  testWidgets('en la web, en español', (tester) async {
    await openList(tester, locale: const Locale('es', 'ES'));
    expect(inTile(lasagneId, 'En la web'), findsOneWidget);
    expect(inTile(minestroneId, 'Sin descripción: no está en la web'), findsOneWidget);
  });

  testWidgets('un plato sin alérgenos lo dice', (tester) async {
    await openList(tester, recipes: [lasagne().copyWith(allergens: const [])]);
    expect(inTile(lasagneId, 'Senza allergeni'), findsOneWidget);
  });

  testWidgets('en español se ve también el nombre en español', (tester) async {
    await openList(tester, locale: const Locale('es', 'ES'));
    expect(inTile(lasagneId, 'Lasagne alla bolognese'), findsOneWidget);
    expect(inTile(lasagneId, 'Lasaña a la boloñesa'), findsOneWidget);
    expect(inTile(lasagneId, 'Gluten · Huevos · Leche y lácteos · Apio'), findsOneWidget);
    expect(inTile(risottoId, 'Vegetariana · sept–nov'), findsOneWidget);
    expect(inTile(frittataId, 'Desactivado'), findsOneWidget);
    expect(find.text('Desactivados (1)'), findsOneWidget);
  });

  testWidgets('búsqueda en los tres idiomas y sin acentos; sin resultados lo dice y se borra', (tester) async {
    await openList(tester);
    final search = byKey('recipes-search');

    await tester.enterText(search, 'hongos');
    await tester.pumpAndSettle();
    expect(tile(risottoId), findsOneWidget);
    expect(tile(lasagneId), findsNothing);
    expect(tile(frittataId), findsNothing);

    await tester.enterText(search, 'MUSHROOM');
    await tester.pumpAndSettle();
    expect(tile(risottoId), findsOneWidget);

    await tester.enterText(search, 'lasana');
    await tester.pumpAndSettle();
    expect(tile(lasagneId), findsOneWidget);
    expect(tile(risottoId), findsNothing);

    await tester.enterText(search, 'zapallitos');
    await tester.pumpAndSettle();
    expect(tile(frittataId), findsOneWidget, reason: 'también los desactivados');

    await tester.enterText(search, 'sushi');
    await tester.pumpAndSettle();
    expect(find.text('Nessun piatto corrisponde a «sushi».'), findsOneWidget);
    await tester.tap(byKey('recipes-search-clear'));
    await tester.pumpAndSettle();
    expect(tile(lasagneId), findsOneWidget);
    expect(tile(frittataId), findsOneWidget);
    expect(find.text('sushi'), findsNothing);
  });

  testWidgets('el campo de búsqueda tiene letra de 16 px (sin zoom en iOS)', (tester) async {
    await openList(tester, size: const Size(375, 667));
    expectReadableInputs(tester);
  });

  testWidgets('tocar un plato abre su editor', (tester) async {
    await openList(tester);
    await tester.tap(tile(risottoId));
    await tester.pumpAndSettle();
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Modifica piatto'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Risotto ai funghi porcini'), findsOneWidget);
  });

  testWidgets('si no se puede cargar: el error con «Riprova»', (tester) async {
    final repository = FakeRecipesRepository(sampleRecipes())..failFetch = true;
    await openList(tester, repository: repository);
    expect(
      find.text('Impossibile caricare i piatti. Controlla la connessione e riprova.'),
      findsOneWidget,
    );
    expect(byKey('recipes-new'), findsNothing);

    repository.failFetch = false;
    await tester.tap(byKey('load-error-retry'));
    await tester.pumpAndSettle();
    expect(tile(lasagneId), findsOneWidget);
  });

  testWidgets('al volver a la lista se actualiza sola, sin deslizar (puede haber cambiado en otro dispositivo)', (
    tester,
  ) async {
    final app = await openList(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(MoreScreen), findsOneWidget);

    app.recipes.recipes[lasagneId] = lasagne().copyWith(nameIt: 'Lasagne verdi');
    await tester.tap(byKey('more-recipes'));
    await tester.pumpAndSettle();
    expect(inTile(lasagneId, 'Lasagne verdi'), findsOneWidget);
    expect(app.recipes.fetchCalls, 2);
  });

  testWidgets('deslizar para actualizar trae lo cargado en otro dispositivo', (tester) async {
    final app = await openList(tester);
    app.recipes.recipes[lasagneId] = lasagne().copyWith(nameIt: 'Lasagne verdi');

    await tester.fling(byKey('recipes-list'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(inTile(lasagneId, 'Lasagne verdi'), findsOneWidget);
  });

  testWidgets('el aviso de guardado sale en la lista y no tapa «Nuovo piatto»', (tester) async {
    final app = await openList(tester, size: const Size(375, 667));
    app.container.read(recipeSavedNoticeProvider.notifier).post(lasagne());
    await tester.pumpAndSettle();

    expect(find.text('«Lasagne alla bolognese» salvato.'), findsOneWidget);
    expect(
      tester.getRect(byKey('recipes-new')).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(SnackBar)).top),
    );
    expect(app.container.read(recipeSavedNoticeProvider), isNull);
  });

  testWidgets('a 375×667, al final de la lista el botón flotante no tapa el último plato', (tester) async {
    await openList(tester, size: const Size(375, 667));
    await tester.drag(byKey('recipes-list'), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(tile(frittataId)).bottom,
      lessThanOrEqualTo(tester.getRect(byKey('recipes-new')).top),
    );
  });

  for (final size in const [Size(375, 667), Size(400, 900), Size(1024, 800)]) {
    for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
      testWidgets('sin desbordes a ${size.width.toInt()}×${size.height.toInt()} (${locale.languageCode})', (
        tester,
      ) async {
        await openList(tester, size: size, locale: locale);
        expect(tester.takeException(), isNull);
        expect(tile(lasagneId), findsOneWidget);
      });
    }
  }
}

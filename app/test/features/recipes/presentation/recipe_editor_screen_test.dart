// Editor de un plato: el alta rápida (nombre, alérgenos, dieta y meses) con
// «Salva» a mano en un iPhone SE, lo que no deja guardar, el error que no
// pierde lo cargado, los ingredientes (cantidad con teclado numérico, «q.b.»,
// sección y orden con botones), duplicar, desactivar y salir sin guardar.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:radici/features/recipes/presentation/recipes_screen.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/text_input_guard.dart';

const String _newId = '0e5b3c1a-2f4d-4a6b-8c9d-000000000001';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));
  Finder tile(String id) => byKey('recipe-$id');

  late FakeRecipesRepository repository;

  setUp(() => repository = FakeRecipesRepository(sampleRecipes()));

  /// La lista de platos con el editor de [location] encima (como al tocar un
  /// plato o «Nuovo piatto»).
  Future<ChefApp> openEditor(
    WidgetTester tester, {
    String location = '/altro/piatti/nuovo',
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
  }) async {
    final ids = [_newId, '0e5b3c1a-2f4d-4a6b-8c9d-000000000002'];
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      recipes: repository,
      location: '/altro/piatti',
      size: size,
      deviceLocales: [locale],
      overrides: [newIdProvider.overrideWithValue(() => ids.removeAt(0))],
    );
    app.go(location);
    await tester.pumpAndSettle();
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
    return app;
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    // Después de escribir, el campo enfocado vuelve a mostrar su cursor en el
    // cuadro siguiente: primero se deja pasar ese cuadro.
    await tester.pumpAndSettle();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(byKey('recipe-save'));
    await tester.pumpAndSettle();
  }

  /// Elige [label] en el desplegable [key].
  Future<void> choose(WidgetTester tester, String key, String label) async {
    await tapVisible(tester, byKey(key));
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('alta rápida a 375×667: nombre, tres alérgenos, dieta y meses; vuelve a la lista con el aviso', (
    tester,
  ) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      recipes: repository,
      location: '/altro/piatti',
      size: const Size(375, 667),
      overrides: [newIdProvider.overrideWithValue(() => _newId)],
    );
    await tester.tap(byKey('recipes-new'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Nuovo piatto'), findsOneWidget);

    // La acción principal, en el tercio inferior.
    final saveButton = byKey('recipe-save');
    expect(tester.getCenter(saveButton).dy, greaterThan(667 * 2 / 3));
    expect(tester.getSize(saveButton).height, greaterThanOrEqualTo(48));

    await tester.enterText(byKey('recipe-name-it'), 'Polpette al sugo');
    for (final allergen in ['gluten', 'eggs', 'milk']) {
      await tapVisible(tester, byKey('recipe-allergen-$allergen'));
    }
    await tapVisible(tester, byKey('recipe-diet-vegetarian'));
    for (final month in [10, 11, 12]) {
      await tapVisible(tester, byKey('recipe-month-$month'));
    }
    await save(tester);

    expect(repository.saveCalls, [
      const Recipe(
        id: _newId,
        nameIt: 'Polpette al sugo',
        diet: Diet.vegetarian,
        allergens: [Allergen.gluten, Allergen.eggs, Allergen.milk],
        seasonMonths: [10, 11, 12],
      ),
    ]);
    expect(find.byType(RecipeEditorScreen), findsNothing);
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(find.text('«Polpette al sugo» salvato.'), findsOneWidget);
    expect(
      find.descendant(of: tile(_newId), matching: find.text('Glutine · Uova · Latte e derivati')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile(_newId), matching: find.text('Vegetariana · ott–dic')),
      findsOneWidget,
    );
  });

  // Si el editor del plato anterior siguiera vivo, el segundo «Nuovo piatto»
  // lo pisaría (mismo id).
  testWidgets('después de guardar, «Nuovo piatto» abre uno vacío con otro id', (tester) async {
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-it'), 'Polpette al sugo');
    await save(tester);
    expect(find.byType(RecipesScreen), findsOneWidget);

    await tester.tap(byKey('recipes-new'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(byKey('recipe-name-it')).controller!.text, isEmpty);
    await tester.enterText(byKey('recipe-name-it'), 'Pollo al limone');
    await save(tester);

    expect(repository.saveCalls.map((r) => r.id), [_newId, '0e5b3c1a-2f4d-4a6b-8c9d-000000000002']);
    expect(repository.recipes[_newId]!.nameIt, 'Polpette al sugo');
  });

  for (final size in const [Size(375, 667), Size(400, 900)]) {
    testWidgets('«Salva» en el tercio inferior y campos de 16 px o más (${size.width.toInt()}×${size.height.toInt()})', (
      tester,
    ) async {
      await openEditor(tester, location: '/altro/piatti/$lasagneId', size: size);
      expect(tester.getCenter(byKey('recipe-save')).dy, greaterThan(size.height * 2 / 3));
      // Todos: nombres, conservación, cada ingrediente y las notas.
      expect(find.byType(EditableText), findsAtLeastNWidgets(10));
      expectReadableInputs(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('sin nombre no guarda: marca el campo y avisa', (tester) async {
    await openEditor(tester);
    await save(tester);

    expect(find.text('Scrivi il nome in italiano.'), findsOneWidget);
    expect(find.text('Controlla i campi segnati.'), findsOneWidget);
    expect(repository.saveCalls, isEmpty);
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
  });

  testWidgets('un plato vegano con latte: lo dice enseguida y no guarda hasta corregirlo', (tester) async {
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-it'), 'Pasta e ceci');
    await tapVisible(tester, byKey('recipe-allergen-milk'));
    await tapVisible(tester, byKey('recipe-diet-vegan'));

    const conflict =
        'Un piatto vegano non contiene Latte e derivati: togli la dieta o questi allergeni.';
    expect(find.text(conflict), findsOneWidget);
    await save(tester);
    expect(repository.saveCalls, isEmpty);

    await tapVisible(tester, byKey('recipe-allergen-milk'));
    expect(find.text(conflict), findsNothing);
    await save(tester);
    expect(repository.saveCalls.single.diet, Diet.vegan);
    expect(repository.saveCalls.single.allergens, isEmpty);
  });

  testWidgets('si falla al guardar: lo dice, no pierde nada y «Riprova» guarda con el mismo id', (tester) async {
    repository.saveFailure = RecipesFailureKind.unavailable;
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-it'), 'Polpette al sugo');
    await tapVisible(tester, byKey('recipe-allergen-gluten'));
    await save(tester);

    expect(
      find.text('Impossibile salvare il piatto. Controlla la connessione e riprova.'),
      findsOneWidget,
    );
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Polpette al sugo'), findsOneWidget);
    expect(
      tester.widget<FilterChip>(byKey('recipe-allergen-gluten')).selected,
      isTrue,
    );

    repository.saveFailure = null;
    await tester.tap(find.widgetWithText(SnackBarAction, 'Riprova'));
    await tester.pumpAndSettle();

    expect(repository.saveCalls.map((r) => r.id), [_newId, _newId]);
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(tile(_newId), findsOneWidget);
  });

  testWidgets('si la base lo rechaza, lo dice con otras palabras', (tester) async {
    repository.saveFailure = RecipesFailureKind.invalid;
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-it'), 'Polpette al sugo');
    await save(tester);
    expect(
      find.text('Il server non ha accettato il piatto. Controlla i dati e riprova.'),
      findsOneWidget,
    );
  });

  testWidgets('ingredientes: cantidad con teclado numérico, «q.b.» sin cantidad, sección y orden con botones', (
    tester,
  ) async {
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-it'), 'Frittata di zucchine');

    await tapVisible(tester, byKey('recipe-ingredient-add'));
    await tester.enterText(byKey('recipe-ingredient-name-0'), 'Zucchine');
    final quantity = byKey('recipe-ingredient-quantity-0');
    expect(tester.widget<TextField>(quantity).keyboardType, TextInputType.number);
    await tester.enterText(quantity, '5a00');
    expect(tester.widget<TextField>(quantity).controller!.text, '500', reason: 'solo cifras');
    await choose(tester, 'recipe-ingredient-section-0', 'Frutta e verdura');

    await tapVisible(tester, byKey('recipe-ingredient-add'));
    await tester.enterText(byKey('recipe-ingredient-name-1'), 'Sale');
    await choose(tester, 'recipe-ingredient-unit-1', 'q.b.');
    expect(
      tester.widget<TextField>(byKey('recipe-ingredient-quantity-1')).enabled,
      isFalse,
      reason: '«q.b.» no lleva cantidad',
    );
    await choose(tester, 'recipe-ingredient-section-1', 'Dispensa');

    await tapVisible(tester, byKey('recipe-ingredient-add'));
    await tester.enterText(byKey('recipe-ingredient-name-2'), 'Uova');
    await tester.enterText(byKey('recipe-ingredient-quantity-2'), '6');
    await choose(tester, 'recipe-ingredient-unit-2', 'pz');
    await choose(tester, 'recipe-ingredient-section-2', 'Latticini e uova');

    // Los botones de orden: el primero no sube y el último no baja.
    expect(tester.widget<IconButton>(byKey('recipe-ingredient-up-0')).onPressed, isNull);
    expect(tester.widget<IconButton>(byKey('recipe-ingredient-down-2')).onPressed, isNull);
    for (final key in ['recipe-ingredient-up-2', 'recipe-ingredient-remove-2']) {
      expect(tester.getSize(byKey(key)).height, greaterThanOrEqualTo(48), reason: key);
    }
    await tapVisible(tester, byKey('recipe-ingredient-up-2'));

    expectReadableInputs(tester);
    await save(tester);

    expect(repository.saveCalls.single.ingredients, const [
      RecipeIngredient(
        name: 'Zucchine',
        section: ShoppingSection.produce,
        amount: (quantity: 500, unit: IngredientUnit.g),
      ),
      RecipeIngredient(
        name: 'Uova',
        section: ShoppingSection.dairyEggs,
        amount: (quantity: 6, unit: IngredientUnit.pcs),
      ),
      RecipeIngredient(name: 'Sale', section: ShoppingSection.pantry),
    ]);
  });

  testWidgets('un ingrediente con unidad y sin cantidad no se guarda', (tester) async {
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-it'), 'Frittata di zucchine');
    await tapVisible(tester, byKey('recipe-ingredient-add'));
    await tester.enterText(byKey('recipe-ingredient-name-0'), 'Zucchine');
    await save(tester);

    expect(find.text('Scrivi la quantità o scegli «q.b.».'), findsOneWidget);
    expect(repository.saveCalls, isEmpty);
  });

  testWidgets('quitar un ingrediente se deshace con «Annulla»', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId');
    await tapVisible(tester, byKey('recipe-ingredient-remove-1'));

    expect(find.widgetWithText(TextField, 'Passata di pomodoro'), findsNothing);
    expect(find.text('Ingrediente tolto.'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Annulla'));
    await tester.pumpAndSettle();

    final names = [
      for (final key in ['recipe-ingredient-name-0', 'recipe-ingredient-name-1', 'recipe-ingredient-name-2'])
        tester.widget<TextField>(byKey(key)).controller!.text,
    ];
    expect(names, ['Carne macinata di manzo', 'Passata di pomodoro', 'Sale']);
    expect(
      tester.getTopLeft(byKey('recipe-ingredient-1')).dy,
      lessThan(tester.getTopLeft(byKey('recipe-ingredient-2')).dy),
      reason: 'vuelve a su lugar',
    );
  });

  testWidgets('«Tutto l\'anno» o meses sueltos', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$risottoId');
    FilterChip chip(String key) => tester.widget<FilterChip>(byKey(key));
    expect(chip('recipe-all-year').selected, isFalse);
    expect(chip('recipe-month-9').selected, isTrue);

    await tapVisible(tester, byKey('recipe-all-year'));
    expect(chip('recipe-all-year').selected, isTrue);
    expect(chip('recipe-month-9').selected, isFalse);
    await save(tester);
    expect(repository.saveCalls.single.seasonMonths, isNull);
  });

  testWidgets('conservación: el freezer aparece al poder congelar', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$risottoId');
    expect(byKey('recipe-freezer-days'), findsNothing);
    await tester.enterText(byKey('recipe-fridge-days'), '45');
    await tapVisible(tester, byKey('recipe-freezable'));
    await tester.enterText(byKey('recipe-freezer-days'), '90');
    await save(tester);
    expect(find.text('Da 0 a 30 giorni.'), findsOneWidget);
    expect(repository.saveCalls, isEmpty);

    await tester.enterText(byKey('recipe-fridge-days'), '3');
    await save(tester);
    final saved = repository.saveCalls.single;
    expect([saved.fridgeDays, saved.freezable, saved.freezerDays], [3, true, 90]);
  });

  testWidgets('duplicar: abre la copia para cambiarle el nombre y guardar crea otro plato', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId');
    await tapVisible(tester, byKey('recipe-duplicate'));

    expect(find.widgetWithText(AppBar, 'Copia del piatto'), findsOneWidget);
    expect(find.text('Copia di «Lasagne alla bolognese»: cambia il nome e salva.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Lasagne alla bolognese'), findsOneWidget);
    expect(find.text('Hai già un piatto con questo nome.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Passata di pomodoro'), findsOneWidget);

    await tester.enterText(byKey('recipe-name-it'), 'Lasagne vegetariane');
    await tester.pump();
    expect(find.text('Hai già un piatto con questo nome.'), findsNothing);
    await save(tester);

    expect(repository.recipes[_newId], lasagne().copyWith(id: _newId, nameIt: 'Lasagne vegetariane'));
    expect(repository.recipes[lasagneId], lasagne());
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(tile(_newId), findsOneWidget);
    expect(tile(lasagneId), findsOneWidget);
  });

  testWidgets('desactivar se ve enseguida y se deshace con «Annulla»', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId');
    const banner = 'Piatto disattivato: non si offre ai clienti né entra nei menù nuovi.';
    expect(find.text(banner), findsNothing);

    await tapVisible(tester, byKey('recipe-deactivate'));
    expect(find.text(banner), findsOneWidget);
    expect(find.text('Piatto disattivato.'), findsOneWidget);
    expect(repository.setActiveCalls, [(id: lasagneId, active: false)]);

    await tester.tap(find.widgetWithText(SnackBarAction, 'Annulla'));
    await tester.pumpAndSettle();
    expect(find.text(banner), findsNothing);
    expect(repository.setActiveCalls.last, (id: lasagneId, active: true));
  });

  testWidgets('un plato desactivado se reactiva desde el aviso de arriba', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$frittataId');
    expect(byKey('recipe-inactive-banner'), findsOneWidget);
    expect(byKey('recipe-deactivate'), findsNothing);

    await tester.tap(byKey('recipe-reactivate'));
    await tester.pumpAndSettle();
    expect(byKey('recipe-inactive-banner'), findsNothing);
    expect(find.text('Piatto riattivato.'), findsOneWidget);
    expect(repository.recipes[frittataId]!.active, isTrue);
  });

  testWidgets('si falla desactivar: lo dice con «Riprova» y el plato sigue activo', (tester) async {
    repository.failSetActive = true;
    await openEditor(tester, location: '/altro/piatti/$lasagneId');
    await tapVisible(tester, byKey('recipe-deactivate'));

    expect(
      find.text('Impossibile aggiornare il piatto. Controlla la connessione e riprova.'),
      findsOneWidget,
    );
    expect(byKey('recipe-inactive-banner'), findsNothing);

    repository.failSetActive = false;
    await tester.tap(find.widgetWithText(SnackBarAction, 'Riprova'));
    await tester.pumpAndSettle();
    expect(byKey('recipe-inactive-banner'), findsOneWidget);
  });

  testWidgets('salir con cambios sin guardar pide confirmación; sin cambios, no', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(RecipesScreen), findsOneWidget, reason: 'sin cambios sale directo');

    await tester.tap(tile(lasagneId));
    await tester.pumpAndSettle();
    await tester.enterText(byKey('recipe-name-it'), 'Lasagne verdi');
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Scartare le modifiche?'), findsOneWidget);

    await tester.tap(byKey('recipe-discard-keep'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Lasagne verdi'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(byKey('recipe-discard-confirm'));
    await tester.pumpAndSettle();
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(find.byType(RecipeEditorScreen), findsNothing);
    expect(repository.saveCalls, isEmpty);
    expect(find.descendant(of: tile(lasagneId), matching: find.text('Lasagne alla bolognese')), findsOneWidget);
  });

  testWidgets('enlace a un plato que no existe: lo dice y vuelve a la lista', (tester) async {
    await openEditor(tester, location: '/altro/piatti/no-existe');
    expect(find.text('Questo piatto non esiste o non è più disponibile.'), findsOneWidget);
    await tester.tap(byKey('recipe-back-to-list'));
    await tester.pumpAndSettle();
    expect(find.byType(RecipesScreen), findsOneWidget);
  });

  testWidgets('enlace directo a un plato: espera el catálogo y lo abre', (tester) async {
    repository.pendingFetch = Completer<void>();
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      recipes: repository,
    );
    app.go('/altro/piatti/$risottoId');
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    repository.pendingFetch!.complete();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Risotto ai funghi porcini'), findsOneWidget);
  });

  testWidgets('a 1024 de ancho el formulario no se estira', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId', size: const Size(1024, 800));
    expect(tester.getSize(byKey('recipe-name-it')).width, lessThanOrEqualTo(720));
    expect(tester.takeException(), isNull);
  });

  for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
    testWidgets('sin desbordes a 375×667 con un plato completo (${locale.languageCode})', (tester) async {
      await openEditor(
        tester,
        location: '/altro/piatti/$lasagneId',
        size: const Size(375, 667),
        locale: locale,
      );
      await tester.drag(byKey('recipe-editor'), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(byKey('recipe-duplicate').hitTestable(), findsOneWidget);
    });
  }
}

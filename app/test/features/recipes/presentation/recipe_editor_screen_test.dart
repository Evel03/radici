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

  // El teclado de un iPhone SE con predicciones y la barra de formulario ocupa
  // unos 300 pt; el de un iPhone de 390×844, unos 336. Flutter web lo informa
  // como viewInsets, y Scaffold no sube la barra de abajo.
  for (final locale in const [Locale('es', 'ES'), Locale('it', 'IT')]) {
    testWidgets('a 375×667, escribiendo el nombre con el teclado abierto, «Salva» queda arriba del teclado (${locale.languageCode})', (
      tester,
    ) async {
      await openEditor(tester, size: const Size(375, 667), locale: locale);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.enterText(byKey('recipe-name-it'), 'Polpette al sugo');
      await tester.pump();

      final save = byKey('recipe-save');
      expect(save.hitTestable(), findsOneWidget);
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(667 - 300));
      expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(of: byKey('recipe-name-it'), matching: find.byType(EditableText)).hitTestable(),
        findsOneWidget,
        reason: 'el campo que se escribe sigue a la vista',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a 390×844, con el teclado abierto en una cantidad, «Salva» queda a mano y guarda', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId', size: const Size(390, 844));
    final quantity = byKey('recipe-ingredient-quantity-1');
    await tapVisible(tester, quantity);
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    await tester.pumpAndSettle();
    await tester.enterText(quantity, '650');
    await tester.pump();

    final save = byKey('recipe-save');
    expect(tester.getRect(save).bottom, lessThanOrEqualTo(844 - 336));
    await tester.tap(save.hitTestable());
    await tester.pumpAndSettle();
    expect(repository.saveCalls.single.ingredients[1].amount, (quantity: 650, unit: IngredientUnit.ml));
  });

  testWidgets('el editor tapa la barra de navegación, nuevo o guardado', (tester) async {
    final app = await openEditor(tester, location: '/altro/piatti/$lasagneId');
    expect(byKey('chef-nav-bar'), findsNothing);
    app.go('/altro/piatti/nuovo');
    await tester.pumpAndSettle();
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
    expect(byKey('chef-nav-bar'), findsNothing);
  });

  // find.text encuentra el error aunque esté fuera de la pantalla: hitTestable
  // exige que se pueda tocar.
  testWidgets('a 375×667, con un error en un ingrediente de abajo, guardar lleva a ese campo', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId', size: const Size(375, 667));
    await tester.enterText(byKey('recipe-ingredient-quantity-1'), '');
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.drag(byKey('recipe-editor'), const Offset(0, 5000));
    await tester.pumpAndSettle();
    final field = find.descendant(of: byKey('recipe-ingredient-quantity-1'), matching: find.byType(EditableText));
    expect(field.hitTestable(), findsNothing, reason: 'arriba de todo, la fila queda fuera de la pantalla');

    await save(tester);
    expect(find.text('Scrivi la quantità o scegli «q.b.».'), findsOneWidget);
    expect(field.hitTestable(), findsOneWidget);
    expect(repository.saveCalls, isEmpty);
  });

  testWidgets('«q.b.» borra la cantidad escrita, y al volver a gramos el campo sigue vacío', (tester) async {
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-it'), 'Frittata di zucchine');
    await tapVisible(tester, byKey('recipe-ingredient-add'));
    await tester.enterText(byKey('recipe-ingredient-name-0'), 'Zucchine');
    await tester.enterText(byKey('recipe-ingredient-quantity-0'), '200');
    TextField quantity() => tester.widget<TextField>(byKey('recipe-ingredient-quantity-0'));

    await choose(tester, 'recipe-ingredient-unit-0', 'q.b.');
    expect(quantity().controller!.text, isEmpty);
    expect(quantity().enabled, isFalse);

    await choose(tester, 'recipe-ingredient-unit-0', 'g');
    expect(quantity().controller!.text, isEmpty, reason: 'lo que se ve es lo que se guarda');
    expect(quantity().enabled, isTrue);
    await save(tester);
    expect(find.text('Scrivi la quantità o scegli «q.b.».'), findsOneWidget);
    expect(repository.saveCalls, isEmpty);
  });

  testWidgets('mientras guarda no se puede salir, aunque la copia no tenga cambios', (tester) async {
    repository.pendingSave = Completer<void>();
    await openEditor(tester, location: '/altro/piatti/nuovo?copia=$lasagneId');
    await tester.tap(byKey('recipe-save'));
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
    expect(byKey('recipe-discard-dialog'), findsNothing, reason: 'no hay nada que descartar');

    repository.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(repository.recipes[_newId], lasagne().copyWith(id: _newId));
  });

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
        'Un piatto vegano non può contenere: Latte e derivati. Togli la dieta o questi allergeni.';
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

  // Sin onEditingComplete, «Siguiente» iría a lo próximo en el orden de
  // lectura: el botón de quitar de la misma fila (y el teclado se cerraría).
  for (final locale in const [Locale('es', 'ES'), Locale('it', 'IT')]) {
    testWidgets('«Siguiente» en el nombre de un ingrediente lleva a su cantidad, con el teclado abierto (${locale.languageCode})', (
      tester,
    ) async {
      await openEditor(tester, size: const Size(375, 667), locale: locale);
      await tester.enterText(byKey('recipe-name-it'), 'Frittata di zucchine');
      await tapVisible(tester, byKey('recipe-ingredient-add'));
      final name = byKey('recipe-ingredient-name-0');
      expect(tester.widget<TextField>(name).textInputAction, TextInputAction.next);
      await tester.enterText(name, 'Zucchine');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();

      final quantity = find.descendant(
        of: byKey('recipe-ingredient-quantity-0'),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(quantity).focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue, reason: 'el teclado sigue abierto');
      expect(byKey('recipe-ingredient-0'), findsOneWidget, reason: 'la fila no se quitó');
    });
  }

  testWidgets('con «q.b.», el nombre del ingrediente cierra el teclado (no hay cantidad que escribir)', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId');
    // La fila 2 (Sale) es q.b.; la 0 lleva cantidad.
    expect(tester.widget<TextField>(byKey('recipe-ingredient-name-2')).textInputAction, TextInputAction.done);
    expect(tester.widget<TextField>(byKey('recipe-ingredient-name-0')).textInputAction, TextInputAction.next);
    await choose(tester, 'recipe-ingredient-unit-0', 'q.b.');
    expect(tester.widget<TextField>(byKey('recipe-ingredient-name-0')).textInputAction, TextInputAction.done);
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

  // En el rotor de VoiceOver los botones de las filas se distinguen por el
  // número, el mismo del campo («2. Ingrediente»).
  testWidgets('los botones de cada fila dicen de qué ingrediente son', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId', locale: const Locale('es', 'ES'));
    expect(
      tester.widget<IconButton>(byKey('recipe-ingredient-remove-1')).tooltip,
      'Quitar el ingrediente 2',
    );
    expect(tester.widget<IconButton>(byKey('recipe-ingredient-up-1')).tooltip, 'Subir el ingrediente 2');
    expect(tester.widget<IconButton>(byKey('recipe-ingredient-down-1')).tooltip, 'Bajar el ingrediente 2');
    expect(find.byTooltip('Quitar el ingrediente 3'), findsOneWidget);

    // Después de mover una fila, el número sigue al lugar.
    await tapVisible(tester, byKey('recipe-ingredient-up-1'));
    expect(tester.widget<IconButton>(byKey('recipe-ingredient-remove-1')).tooltip, 'Quitar el ingrediente 1');
  });

  testWidgets('las ayudas en español: el nombre principal y la lista de la compra para el cliente, con las cantidades que se ajustan a las porciones', (
    tester,
  ) async {
    await openEditor(tester, locale: const Locale('es', 'ES'));
    expect(find.text('Es el nombre principal: los clientes lo ven si no hay traducción.'), findsOneWidget);
    expect(find.text('Ingredientes para 4 porciones'), findsOneWidget);
    expect(
      find.text(
        'De aquí sale la lista de la compra que le mandas al cliente: las cantidades se ajustan a las porciones de cada sesión.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('quitar un ingrediente se deshace con «Annulla»', (tester) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId');
    await tapVisible(tester, byKey('recipe-ingredient-remove-1'));

    expect(find.widgetWithText(TextField, 'Passata di pomodoro'), findsNothing);
    expect(find.text('Ingrediente rimosso.'), findsOneWidget);
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

  testWidgets('la descripción de la web: la ayuda, los tres campos con lo guardado y se guarda recortada', (
    tester,
  ) async {
    await openEditor(tester, location: '/altro/piatti/$lasagneId');
    expect(find.text('Descrizione sul sito'), findsOneWidget);
    expect(
      find.text(
        'Una frase breve: compare sul sito, nel modulo di richiesta, accanto al nome. '
        'Senza la descrizione in italiano il piatto non si vede sul sito. '
        'In spagnolo e in inglese, se manca, si vede quella in italiano.',
      ),
      findsOneWidget,
    );
    String text(String key) => tester.widget<TextField>(byKey(key)).controller!.text;
    expect(text('recipe-description-it'), 'Ragù cotto piano e besciamella fatta in casa.');
    expect(text('recipe-description-es'), 'Ragú cocido despacio y bechamel casera.');
    expect(text('recipe-description-en'), isEmpty);
    expect(find.widgetWithText(TextField, 'Descrizione in italiano'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Descrizione in spagnolo'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Descrizione in inglese'), findsOneWidget);
    // Una línea: el teclado no ofrece salto de línea (la base no lo acepta).
    final field = tester.widget<TextField>(byKey('recipe-description-it'));
    expect(field.keyboardType, TextInputType.text);
    expect(field.maxLength, 200);

    await tapVisible(tester, byKey('recipe-description-en'));
    await tester.enterText(byKey('recipe-description-en'), '  Slow-cooked   ragù. ');
    await tester.enterText(byKey('recipe-description-es'), '   ');
    await save(tester);

    final saved = repository.saveCalls.single;
    expect(saved.descriptionIt, 'Ragù cotto piano e besciamella fatta in casa.');
    expect(saved.descriptionEs, isNull);
    expect(saved.descriptionEn, 'Slow-cooked ragù.');
  });

  testWidgets('a 375×667, una descripción de más de 200 caracteres no se guarda y lleva al error', (tester) async {
    await openEditor(tester, size: const Size(375, 667));
    await tester.enterText(byKey('recipe-name-it'), 'Pasta al pesto');
    await tapVisible(tester, byKey('recipe-description-it'));
    await tester.enterText(byKey('recipe-description-it'), 'd' * 201);
    await tester.drag(byKey('recipe-editor'), const Offset(0, 3000));
    await tester.pumpAndSettle();
    await save(tester);

    expect(repository.saveCalls, isEmpty);
    expect(find.text('Al massimo 200 caratteri.').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    const banner = 'Piatto disattivato: non viene proposto ai clienti e non entra nei nuovi menù.';
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

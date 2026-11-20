// Editor de un plato: el alta rápida (nombre en español, alérgenos, dieta y
// meses) con «Salva» a mano en un iPhone SE, lo que no deja guardar, el error
// que no pierde lo cargado, los ingredientes (cantidad con teclado numérico,
// «q.b.», sección y orden con botones), duplicar, desactivar y salir sin
// guardar. La traducción automática: el español primero, la marca en lo
// automático, «Traduzione in corso…» y el aviso cuando falla, también con
// letra grande.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
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
  late FakeTranslationRepository translator;

  setUp(() {
    repository = FakeRecipesRepository([...sampleRecipes(), milanesa()]);
    translator = FakeTranslationRepository();
  });

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
      overrides: [
        newIdProvider.overrideWithValue(() => ids.removeAt(0)),
        translationRepositoryProvider.overrideWithValue(translator),
      ],
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

  testWidgets('alta rápida a 375×667: nombre en español, tres alérgenos, dieta y meses; vuelve a la lista con el aviso', (
    tester,
  ) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      recipes: repository,
      location: '/altro/piatti',
      size: const Size(375, 667),
      overrides: [
        newIdProvider.overrideWithValue(() => _newId),
        translationRepositoryProvider.overrideWithValue(translator),
      ],
    );
    await tester.tap(byKey('recipes-new'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Nuovo piatto'), findsOneWidget);

    // La acción principal, en el tercio inferior.
    final saveButton = byKey('recipe-save');
    expect(tester.getCenter(saveButton).dy, greaterThan(667 * 2 / 3));
    expect(tester.getSize(saveButton).height, greaterThanOrEqualTo(48));

    await tester.enterText(byKey('recipe-name-es'), 'Albóndigas con salsa');
    for (final allergen in ['gluten', 'eggs', 'milk']) {
      await tapVisible(tester, byKey('recipe-allergen-$allergen'));
    }
    await tapVisible(tester, byKey('recipe-diet-vegetarian'));
    for (final month in [10, 11, 12]) {
      await tapVisible(tester, byKey('recipe-month-$month'));
    }
    await save(tester);

    expect(translator.calls, [(name: 'Albóndigas con salsa', description: null)]);
    expect(repository.saveCalls, [
      const Recipe(
        id: _newId,
        nameIt: '[it] Albóndigas con salsa',
        nameEs: 'Albóndigas con salsa',
        nameEn: '[en] Albóndigas con salsa',
        autoTranslated: {TranslatedField.nameIt, TranslatedField.nameEn},
        diet: Diet.vegetarian,
        allergens: [Allergen.gluten, Allergen.eggs, Allergen.milk],
        seasonMonths: [10, 11, 12],
      ),
    ]);
    expect(find.byType(RecipeEditorScreen), findsNothing);
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(find.text('«[it] Albóndigas con salsa» salvato.'), findsOneWidget);
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
    await tester.enterText(byKey('recipe-name-es'), 'Albóndigas con salsa');
    await save(tester);
    expect(find.byType(RecipesScreen), findsOneWidget);

    await tester.tap(byKey('recipes-new'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(byKey('recipe-name-es')).controller!.text, isEmpty);
    expect(tester.widget<TextField>(byKey('recipe-name-it')).controller!.text, isEmpty);
    await tester.enterText(byKey('recipe-name-es'), 'Pollo al limón');
    await save(tester);

    expect(repository.saveCalls.map((r) => r.id), [_newId, '0e5b3c1a-2f4d-4a6b-8c9d-000000000002']);
    expect(repository.recipes[_newId]!.nameEs, 'Albóndigas con salsa');
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
      await tester.enterText(byKey('recipe-name-es'), 'Albóndigas con salsa');
      await tester.pump();

      final save = byKey('recipe-save');
      expect(save.hitTestable(), findsOneWidget);
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(667 - 300));
      expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(of: byKey('recipe-name-es'), matching: find.byType(EditableText)).hitTestable(),
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
    await tester.enterText(byKey('recipe-name-es'), 'Tortilla de zapallitos');
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
    expect(repository.recipes[_newId], lasagne().copyWith(id: _newId, descriptionIt: null, descriptionEs: null));
  });

  testWidgets('sin nombre no guarda: marca el campo y avisa', (tester) async {
    await openEditor(tester);
    await save(tester);

    expect(find.text('Scrivi il nome in spagnolo.'), findsOneWidget);
    expect(find.text('Scrivi il nome in italiano.'), findsNothing, reason: 'el italiano sale del español');
    expect(find.text('Controlla i campi segnati.'), findsOneWidget);
    expect(translator.calls, isEmpty);
    expect(repository.saveCalls, isEmpty);
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
  });

  testWidgets('un plato vegano con latte: lo dice enseguida y no guarda hasta corregirlo', (tester) async {
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-es'), 'Pasta con garbanzos');
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
    await tester.enterText(byKey('recipe-name-es'), 'Albóndigas con salsa');
    await tapVisible(tester, byKey('recipe-allergen-gluten'));
    await save(tester);

    expect(
      find.text('Impossibile salvare il piatto. Controlla la connessione e riprova.'),
      findsOneWidget,
    );
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Albóndigas con salsa'), findsOneWidget);
    // Lo traducido queda en los campos, con la marca; el reintento no vuelve
    // a traducir.
    expect(tester.widget<TextField>(byKey('recipe-name-it')).controller!.text, '[it] Albóndigas con salsa');
    expect(byKey('recipe-auto-name_it'), findsOneWidget);
    expect(
      tester.widget<FilterChip>(byKey('recipe-allergen-gluten')).selected,
      isTrue,
    );

    repository.saveFailure = null;
    await tester.tap(find.widgetWithText(SnackBarAction, 'Riprova'));
    await tester.pumpAndSettle();

    expect(repository.saveCalls.map((r) => r.id), [_newId, _newId]);
    expect(translator.calls, hasLength(1));
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(tile(_newId), findsOneWidget);
  });

  testWidgets('si la base lo rechaza, lo dice con otras palabras', (tester) async {
    repository.saveFailure = RecipesFailureKind.invalid;
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-es'), 'Albóndigas con salsa');
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
    await tester.enterText(byKey('recipe-name-es'), 'Tortilla de zapallitos');

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
      await tester.enterText(byKey('recipe-name-es'), 'Tortilla de zapallitos');
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
    await tester.enterText(byKey('recipe-name-es'), 'Tortilla de zapallitos');
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
        "Scrivila in spagnolo: l'italiano e l'inglese si traducono quando salvi. "
        'Senza la descrizione in italiano il piatto non si vede sul sito.',
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
    // El contador, sin cortar lo escrito (no hay maxLength).
    expect(field.maxLength, isNull);
    expect(find.descendant(of: byKey('recipe-description-it'), matching: find.text('45/200')), findsOneWidget);
    expect(find.descendant(of: byKey('recipe-description-en'), matching: find.text('0/200')), findsOneWidget);

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
    await tester.enterText(byKey('recipe-name-es'), 'Pasta al pesto');
    await tapVisible(tester, byKey('recipe-description-es'));
    await tester.enterText(byKey('recipe-description-es'), 'd' * 201);
    await tester.drag(byKey('recipe-editor'), const Offset(0, 3000));
    await tester.pumpAndSettle();
    await save(tester);

    expect(repository.saveCalls, isEmpty);
    expect(translator.calls, isEmpty);
    expect(find.text('Al massimo 200 caratteri.').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // El contador cuenta como la validación (y como char_length en la base): el
  // texto sin espacios de más, por caracteres. El de TextField contaba lo
  // escrito, por letras.
  group('el contador de la descripción cuenta como la validación', () {
    Finder counter(String text) => find.descendant(of: byKey('recipe-description-es'), matching: find.text(text));

    testWidgets('los espacios de más no cuentan: «200/200» y se guarda', (tester) async {
      await openEditor(tester);
      await tester.enterText(byKey('recipe-name-es'), 'Pasta al pesto');
      await tapVisible(tester, byKey('recipe-description-es'));
      // 205 escritos: la base guarda un solo espacio entre las dos partes.
      await tester.enterText(byKey('recipe-description-es'), '${'d' * 100}${' ' * 6}${'d' * 99}');
      await tester.pump();

      expect(counter('200/200'), findsOneWidget);
      expect(tester.widget<TextField>(byKey('recipe-description-es')).decoration!.errorText, isNull);
      await save(tester);
      expect(textLength(repository.saveCalls.single.descriptionEs!), 200);
    });

    testWidgets('una bandera cuenta dos: «201/200» en rojo y no se guarda', (tester) async {
      await openEditor(tester);
      await tester.enterText(byKey('recipe-name-es'), 'Pasta al pesto');
      await tapVisible(tester, byKey('recipe-description-es'));
      // 101 letras a la vista, 201 caracteres para la base.
      await tester.enterText(byKey('recipe-description-es'), '${'🇮🇹' * 100}d');
      await tester.pump();

      expect(counter('201/200'), findsOneWidget);
      expect(tester.widget<TextField>(byKey('recipe-description-es')).decoration!.errorText, isNotNull);
      await save(tester);
      expect(repository.saveCalls, isEmpty);
      expect(find.text('Al massimo 200 caratteri.'), findsOneWidget);
    });
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
    // Las descripciones de la web no se copian: la copia no sale en la web
    // con las del original.
    for (final language in ['it', 'es', 'en']) {
      expect(tester.widget<TextField>(byKey('recipe-description-$language')).controller!.text, isEmpty);
    }

    await tester.enterText(byKey('recipe-name-it'), 'Lasagne vegetariane');
    await tester.pump();
    expect(find.text('Hai già un piatto con questo nome.'), findsNothing);
    await save(tester);

    expect(
      repository.recipes[_newId],
      lasagne().copyWith(id: _newId, nameIt: 'Lasagne vegetariane', descriptionIt: null, descriptionEs: null),
    );
    expect(repository.recipes[lasagneId], lasagne());
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(tile(_newId), findsOneWidget);
    expect(tile(lasagneId), findsOneWidget);
    expect(find.descendant(of: tile(_newId), matching: find.text('Senza descrizione: non è sul sito')), findsOneWidget);
    expect(find.descendant(of: tile(lasagneId), matching: find.text('Sul sito')), findsOneWidget);
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

  // El español es la fuente (SPEC §4): primero el nombre y la descripción en
  // español; el italiano y el inglés los llena la traducción al guardar.
  group('la traducción automática', () {
    Finder field(String key) => find.descendant(of: byKey(key), matching: find.byType(EditableText));
    String textOf(WidgetTester tester, String key) => tester.widget<TextField>(byKey(key)).controller!.text;

    testWidgets('el español primero: nombre y descripción, el aviso de privacidad y abajo el italiano y el inglés', (
      tester,
    ) async {
      await openEditor(tester, size: const Size(375, 667), locale: const Locale('es', 'ES'));
      double top(String key) => tester.getTopLeft(byKey(key)).dy;
      for (final (above, below) in const [
        ('recipe-name-es', 'recipe-description-es'),
        ('recipe-description-es', 'recipe-privacy-hint'),
        ('recipe-privacy-hint', 'recipe-allergen-gluten'),
        ('recipe-allergen-gluten', 'recipe-name-it'),
        ('recipe-name-it', 'recipe-description-it'),
        ('recipe-description-it', 'recipe-name-en'),
        ('recipe-name-en', 'recipe-description-en'),
        ('recipe-description-en', 'recipe-fridge-days'),
      ]) {
        expect(top(above), lessThan(top(below)), reason: '$above antes que $below');
      }
      // El nombre en español, a la vista y con el teclado listo.
      expect(field('recipe-name-es').hitTestable(), findsOneWidget);
      expect(tester.widget<EditableText>(field('recipe-name-es')).focusNode.hasFocus, isTrue);
      expect(find.widgetWithText(TextField, 'Nombre en español'), findsOneWidget);
      expect(find.text('El nombre en italiano y en inglés se traduce de aquí al guardar.'), findsOneWidget);
      expect(
        find.text(
          'No escribas datos de clientes (nombres, direcciones, salud): el nombre y la descripción van al '
          'servicio de traducción automática.',
        ),
        findsOneWidget,
      );
      expect(find.text('Italiano e inglés'), findsOneWidget);
      expect(find.text('Traducido automáticamente'), findsNothing, reason: 'un plato nuevo no tiene nada traducido');
    });

    testWidgets('la marca en los campos automáticos; escribir en uno a mano la saca', (tester) async {
      await openEditor(tester, location: '/altro/piatti/$milanesaId', locale: const Locale('es', 'ES'));
      expect(byKey('recipe-auto-description_it'), findsOneWidget);
      expect(byKey('recipe-auto-name_en'), findsOneWidget);
      expect(byKey('recipe-auto-description_en'), findsOneWidget);
      expect(byKey('recipe-auto-name_it'), findsNothing, reason: 'Evelyn lo corrigió a mano');
      expect(
        find.descendant(of: byKey('recipe-name-en'), matching: find.text('Traducido automáticamente')),
        findsOneWidget,
      );

      await tapVisible(tester, byKey('recipe-name-en'));
      await tester.enterText(byKey('recipe-name-en'), 'Neapolitan milanese');
      await tester.pump();
      expect(byKey('recipe-auto-name_en'), findsNothing);
      await save(tester);

      expect(translator.calls, isEmpty, reason: 'el español no cambió');
      expect(repository.saveCalls.single.nameEn, 'Neapolitan milanese');
      expect(repository.saveCalls.single.autoTranslated, {
        TranslatedField.descriptionIt,
        TranslatedField.descriptionEn,
      });
    });

    testWidgets('mientras traduce lo dice en el botón y no deja guardar de nuevo, tocar el formulario ni salir', (
      tester,
    ) async {
      translator.pending = Completer<void>();
      await openEditor(tester, size: const Size(375, 667));
      await tester.enterText(byKey('recipe-name-es'), 'Milanesa a la napolitana');
      await tester.pumpAndSettle();
      await tester.ensureVisible(byKey('recipe-allergen-gluten'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('recipe-save'));
      await tester.pump();

      expect(find.text('Traduzione in corso…'), findsOneWidget);
      expect(tester.widget<FilledButton>(byKey('recipe-save')).onPressed, isNull);
      await tester.tap(byKey('recipe-save'), warnIfMissed: false);
      await tester.tap(byKey('recipe-allergen-gluten'), warnIfMissed: false);
      await tester.pump();
      expect(
        tester.widget<FilterChip>(byKey('recipe-allergen-gluten')).selected,
        isFalse,
        reason: 'la traducción pisaría lo que se cambie',
      );
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(RecipeEditorScreen), findsOneWidget);
      expect(byKey('recipe-discard-dialog'), findsNothing);
      expect(translator.calls, hasLength(1));
      expect(tester.takeException(), isNull);

      translator.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(RecipesScreen), findsOneWidget);
      expect(repository.saveCalls.single.nameIt, '[it] Milanesa a la napolitana');
      expect(repository.saveCalls.single.allergens, isEmpty);
    });

    testWidgets('si el traductor no responde: lo dice, no guarda ni pierde nada y «Riprova» traduce y guarda', (
      tester,
    ) async {
      translator.failure = TranslationFailureKind.unavailable;
      await openEditor(tester, size: const Size(375, 667));
      await tester.enterText(byKey('recipe-name-es'), 'Locro');
      await save(tester);

      expect(byKey('recipe-translate-failed'), findsOneWidget);
      expect(find.text('Traduzione non riuscita'), findsOneWidget);
      expect(find.text('La traduzione automatica non risponde in questo momento.'), findsOneWidget);
      // Un plato nuevo no se puede guardar sin el nombre en italiano.
      expect(
        find.text(
          'Quello che hai scritto non si è perso. Per salvare senza traduzione scrivi tu il nome in italiano.',
        ),
        findsOneWidget,
      );
      expect(byKey('recipe-translate-skip'), findsNothing);
      for (final key in ['recipe-translate-retry', 'recipe-translate-write']) {
        expect(tester.getSize(byKey(key)).height, greaterThanOrEqualTo(48), reason: key);
      }
      expect(repository.saveCalls, isEmpty);
      expect(textOf(tester, 'recipe-name-es'), 'Locro');

      translator.failure = null;
      await tester.tap(byKey('recipe-translate-retry'));
      await tester.pumpAndSettle();
      expect(translator.calls, hasLength(2));
      expect(find.byType(RecipesScreen), findsOneWidget);
      expect(repository.saveCalls.single.nameIt, '[it] Locro');
    });

    testWidgets('traducción apagada en un plato nuevo: sin «Reintentar»; «Las escribo yo» lleva al nombre en italiano y después se guarda sin traducir', (
      tester,
    ) async {
      translator.failure = TranslationFailureKind.notConfigured;
      await openEditor(tester, size: const Size(375, 667), locale: const Locale('es', 'ES'));
      await tester.enterText(byKey('recipe-name-es'), 'Locro');
      await save(tester);

      expect(find.text('La traducción automática está apagada: escribe tú el italiano y el inglés.'), findsOneWidget);
      expect(byKey('recipe-translate-retry'), findsNothing);
      expect(byKey('recipe-translate-skip'), findsNothing);
      await tester.tap(byKey('recipe-translate-write'));
      await tester.pumpAndSettle();
      expect(byKey('recipe-translate-failed'), findsNothing);
      expect(field('recipe-name-it').hitTestable(), findsOneWidget);
      expect(tester.widget<EditableText>(field('recipe-name-it')).focusNode.hasFocus, isTrue);
      expect(textOf(tester, 'recipe-name-es'), 'Locro', reason: 'lo escrito queda');

      await tester.enterText(byKey('recipe-name-it'), 'Locro');
      await save(tester);
      // El inglés vacío también se iba a traducir: ahora se puede guardar sin.
      expect(byKey('recipe-translate-failed'), findsOneWidget);
      expect(
        find.text(
          'Lo que escribiste no se perdió. Puedes escribir tú las traducciones o guardar sin ellas: los campos '
          'por traducir quedan vacíos y se traducen la próxima vez que guardes.',
        ),
        findsOneWidget,
      );
      await tester.tap(byKey('recipe-translate-skip'));
      await tester.pumpAndSettle();

      expect(find.byType(RecipesScreen), findsOneWidget);
      expect(repository.saveCalls.single, const Recipe(id: _newId, nameIt: 'Locro', nameEs: 'Locro'));
      expect(translator.calls, hasLength(2));
    });

    testWidgets('cambió la descripción de un plato en la web y se pasó el límite: sin «Riprova»; «Salva senza tradurre» avisa que sale de la web', (
      tester,
    ) async {
      translator.failure = TranslationFailureKind.rateLimited;
      await openEditor(tester, location: '/altro/piatti/$milanesaId', size: const Size(375, 667));
      await tapVisible(tester, byKey('recipe-description-es'));
      await tester.enterText(byKey('recipe-description-es'), 'Con tomate y queso.');
      await save(tester);

      expect(find.text("Hai chiesto molte traduzioni nell'ultima ora: riprova più tardi."), findsOneWidget);
      expect(
        find.text(
          'Quello che hai scritto non si è perso. Puoi scrivere tu le traduzioni o salvare senza: i campi da '
          'tradurre restano vuoti e si traducono la prossima volta che salvi. Senza la descrizione in italiano '
          'il piatto non è sul sito.',
        ),
        findsOneWidget,
      );
      expect(byKey('recipe-translate-retry'), findsNothing, reason: 'ante un 429 la app no reintenta');
      expect(tester.getSize(byKey('recipe-translate-skip')).height, greaterThanOrEqualTo(48));
      await tester.tap(byKey('recipe-translate-skip'));
      await tester.pumpAndSettle();

      final saved = repository.saveCalls.single;
      expect(saved.descriptionEs, 'Con tomate y queso.');
      expect([saved.descriptionIt, saved.descriptionEn], [null, null], reason: 'nunca la traducción vieja');
      expect(saved.nameEn, milanesa().nameEn, reason: 'el nombre en español no cambió');
      expect(find.byType(RecipesScreen), findsOneWidget);
      expect(
        find.descendant(of: tile(milanesaId), matching: find.text('Senza descrizione: non è sul sito')),
        findsOneWidget,
      );
    });

    testWidgets('Claude no lo tradujo: sin «Riprova» y con la salida de escribirlo a mano', (tester) async {
      translator.failure = TranslationFailureKind.untranslatable;
      await openEditor(tester, location: '/altro/piatti/$milanesaId', locale: const Locale('en'));
      await tester.enterText(byKey('recipe-name-es'), 'Milanesa napolitana');
      await save(tester);

      expect(find.text("Automatic translation couldn't translate this text: retrying won't help."), findsOneWidget);
      expect(byKey('recipe-translate-retry'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Save without translating'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, "I'll write them"));
      await tester.pumpAndSettle();
      expect(repository.saveCalls, isEmpty);
      expect(textOf(tester, 'recipe-name-es'), 'Milanesa napolitana');
      expect(byKey('recipe-auto-name_en'), findsOneWidget, reason: 'nada cambió: sigue siendo automático');
    });

    // Texto grande: en el iPhone, los tamaños de accesibilidad empiezan en
    // ≈1.65.
    for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
      testWidgets('con el texto al doble a 375×667 (${locale.languageCode}): marcas, «traduciendo» y el aviso sin desbordes', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await openEditor(tester, location: '/altro/piatti/$milanesaId', size: const Size(375, 667), locale: locale);
        expect(tester.takeException(), isNull);
        await tapVisible(tester, byKey('recipe-auto-description_en'));
        expect(tester.takeException(), isNull);

        await tester.drag(byKey('recipe-editor'), const Offset(0, 5000));
        await tester.pumpAndSettle();
        translator
          ..pending = Completer<void>()
          ..failure = TranslationFailureKind.timeout;
        await tester.enterText(byKey('recipe-name-es'), 'Milanesa napolitana');
        await tester.pumpAndSettle();
        await tester.tap(byKey('recipe-save'));
        await tester.pump();
        expect(byKey('recipe-translating'), findsOneWidget);
        expect(tester.getSize(byKey('recipe-save')).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);

        translator.pending!.complete();
        await tester.pumpAndSettle();
        expect(byKey('recipe-translate-failed'), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final key in ['recipe-translate-retry', 'recipe-translate-skip', 'recipe-translate-write']) {
          expect(byKey(key).hitTestable(), findsOneWidget, reason: key);
          expect(tester.getSize(byKey(key)).height, greaterThanOrEqualTo(48), reason: key);
        }
        await tester.tap(byKey('recipe-translate-write'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(repository.saveCalls, isEmpty);
      });
    }
  });
}

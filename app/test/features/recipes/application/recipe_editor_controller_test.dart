// Editor de un plato: nuevo, guardado o copia; los chips de alérgenos, dieta
// y meses; las filas de ingredientes (agregar, mover, quitar y deshacer); el
// guardado con el mismo id en cada reintento, y desactivar o reactivar.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/application/recipe_editor_controller.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

const String _id1 = '0e5b3c1a-2f4d-4a6b-8c9d-000000000001';
const String _id2 = '0e5b3c1a-2f4d-4a6b-8c9d-000000000002';

void main() {
  late FakeRecipesRepository repository;
  late ProviderContainer container;
  late List<String> nextIds;

  const create = RecipeEditorTarget.create();
  const editLasagne = RecipeEditorTarget.edit(lasagneId);
  const editFrittata = RecipeEditorTarget.edit(frittataId);
  const copyLasagne = RecipeEditorTarget.copy(lasagneId);

  Future<void> start() async {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(FakeAuthRepository(user: chefUser)),
        accountRepositoryProvider.overrideWithValue(FakeAccountRepository(chefAccountData)),
        recipesRepositoryProvider.overrideWithValue(repository),
        newIdProvider.overrideWithValue(() => nextIds.removeAt(0)),
      ],
    );
    container.listen(recipeCatalogProvider, (_, _) {});
    await pumpEventQueue();
  }

  /// El editor de [target], abierto (como la pantalla, lo escucha).
  RecipeEditorController open(RecipeEditorTarget target) {
    container.listen(recipeEditorProvider(target), (_, _) {});
    return container.read(recipeEditorProvider(target).notifier);
  }

  RecipeEditorState stateOf(RecipeEditorTarget target) => container.read(recipeEditorProvider(target));
  Recipe? inCatalog(String id) =>
      container.read(recipeCatalogProvider).requireValue.where((r) => r.id == id).firstOrNull;

  setUp(() {
    repository = FakeRecipesRepository(sampleRecipes());
    nextIds = [_id1, _id2];
  });

  group('al abrir', () {
    test('uno nuevo: vacío, con un id generado en el teléfono', () async {
      await start();
      open(create);
      final state = stateOf(create);
      expect(state.draft, emptyRecipeDraft(_id1));
      expect(state.isNew, isTrue);
      expect(state.source, isNull);
      expect(state.dirty, isFalse);
      expect(state.showErrors, isFalse);
    });

    test('uno guardado: el formulario del plato del catálogo', () async {
      await start();
      open(editLasagne);
      final state = stateOf(editLasagne);
      expect(state.draft, recipeDraftFrom(lasagne()));
      expect(state.isNew, isFalse);
      expect(state.source, lasagne());
    });

    test('una copia: el mismo plato con un id nuevo, todavía sin guardar', () async {
      await start();
      open(copyLasagne);
      final state = stateOf(copyLasagne);
      expect(state.draft, recipeDraftFrom(lasagne(), id: _id1));
      expect(state.isNew, isTrue);
      expect(state.source, lasagne());
      expect(state.dirty, isFalse);
    });
  });

  group('chips', () {
    test('alérgenos y dieta', () async {
      await start();
      final editor = open(create)
        ..toggleAllergen(Allergen.milk)
        ..toggleAllergen(Allergen.gluten)
        ..toggleAllergen(Allergen.milk)
        ..setDiet(Diet.vegan);
      expect(stateOf(create).draft.allergens, {Allergen.gluten});
      expect(stateOf(create).draft.diet, Diet.vegan);
      editor.setDiet(null);
      expect(stateOf(create).draft.diet, isNull);
      expect(stateOf(create).dirty, isTrue);
    });

    test('meses: «todo el año» los borra y los 12 vuelven a «todo el año»', () async {
      await start();
      final editor = open(create)
        ..toggleMonth(9)
        ..toggleMonth(10)
        ..toggleMonth(11)
        ..toggleMonth(10);
      expect(stateOf(create).draft.months, {9, 11});
      editor.setAllYear();
      expect(stateOf(create).draft.months, isEmpty);

      for (var month = 1; month <= 11; month++) {
        editor.toggleMonth(month);
      }
      expect(stateOf(create).draft.months, hasLength(11));
      editor.toggleMonth(12);
      expect(stateOf(create).draft.months, isEmpty, reason: 'los 12 son todo el año');
    });

    test('textos y conservación', () async {
      await start();
      open(create)
        ..setNameIt('Pasta al pesto')
        ..setNameEs('Pasta al pesto')
        ..setNameEn('Pesto pasta')
        ..setNotes('Senza aglio.')
        ..setFridgeDays('2')
        ..setFreezable(true)
        ..setFreezerDays('30');
      final draft = stateOf(create).draft;
      expect(
        [draft.nameIt, draft.nameEs, draft.nameEn, draft.notes, draft.fridgeDays, draft.freezerDays],
        ['Pasta al pesto', 'Pasta al pesto', 'Pesto pasta', 'Senza aglio.', '2', '30'],
      );
      expect(draft.freezable, isTrue);
    });

    test('las descripciones de la web en los tres idiomas', () async {
      await start();
      open(create)
        ..setDescriptionIt('Basilico fresco e pinoli.')
        ..setDescriptionEs('Albahaca fresca y piñones.')
        ..setDescriptionEn('Fresh basil and pine nuts.');
      final draft = stateOf(create).draft;
      expect(
        [draft.descriptionIt, draft.descriptionEs, draft.descriptionEn],
        ['Basilico fresco e pinoli.', 'Albahaca fresca y piñones.', 'Fresh basil and pine nuts.'],
      );
      expect(stateOf(create).dirty, isTrue);
    });
  });

  group('ingredientes', () {
    test('agregar: gramos y la sección del de arriba', () async {
      await start();
      final editor = open(create);
      final first = editor.addIngredient()!;
      expect(stateOf(create).draft.ingredients.single, IngredientDraft(key: first));
      editor.updateIngredient(first, section: ShoppingSection.produce);
      final second = editor.addIngredient()!;
      expect(second, isNot(first));
      expect(stateOf(create).draft.ingredients.last.section, ShoppingSection.produce);
      expect(stateOf(create).draft.ingredients.last.unit, UnitChoice.g);
    });

    test('cambiar una fila no toca las otras', () async {
      await start();
      final editor = open(create);
      final a = editor.addIngredient()!;
      final b = editor.addIngredient()!;
      editor
        ..updateIngredient(b, name: 'Sale', unit: UnitChoice.toTaste, section: ShoppingSection.pantry)
        ..updateIngredient(a, name: 'Zucchine', quantity: '500');
      expect(stateOf(create).draft.ingredients, [
        IngredientDraft(key: a, name: 'Zucchine', quantity: '500'),
        IngredientDraft(key: b, name: 'Sale', unit: UnitChoice.toTaste, section: ShoppingSection.pantry),
      ]);
    });

    test('mover arriba y abajo; en los bordes no hace nada', () async {
      await start();
      final editor = open(editLasagne);
      List<String> names() => [for (final row in stateOf(editLasagne).draft.ingredients) row.name];
      final keys = [for (final row in stateOf(editLasagne).draft.ingredients) row.key];

      editor.moveIngredient(keys[0], 1);
      expect(names(), ['Passata di pomodoro', 'Carne macinata di manzo', 'Sale']);
      editor.moveIngredient(keys[2], -1);
      expect(names(), ['Passata di pomodoro', 'Sale', 'Carne macinata di manzo']);
      editor
        ..moveIngredient(keys[1], -1)
        ..moveIngredient(keys[0], 1);
      expect(names(), ['Passata di pomodoro', 'Sale', 'Carne macinata di manzo']);
    });

    test('quitar devuelve la fila y deshacer la pone en su lugar', () async {
      await start();
      final editor = open(editLasagne);
      final middle = stateOf(editLasagne).draft.ingredients[1];

      final removed = editor.removeIngredient(middle.key)!;
      expect(removed.index, 1);
      expect(stateOf(editLasagne).draft.ingredients.map((r) => r.name), [
        'Carne macinata di manzo',
        'Sale',
      ]);

      editor.restoreIngredient(removed);
      expect(stateOf(editLasagne).draft, recipeDraftFrom(lasagne()));
      expect(stateOf(editLasagne).dirty, isFalse);
      expect(editor.removeIngredient(999), isNull);
    });

    test('hasta 50 filas', () async {
      await start();
      final editor = open(create);
      for (var i = 0; i < maxIngredients; i++) {
        expect(editor.addIngredient(), isNotNull);
      }
      expect(editor.addIngredient(), isNull);
      expect(stateOf(create).draft.ingredients, hasLength(maxIngredients));
    });
  });

  group('guardar', () {
    test('sin nombre no manda nada y muestra los errores', () async {
      await start();
      final editor = open(create);
      expect(await editor.save(), RecipeSaveResult.invalid);
      expect(stateOf(create).showErrors, isTrue);
      expect(stateOf(create).errors.nameIt, TextError.required);
      expect(repository.saveCalls, isEmpty);
    });

    test('alta rápida: nombre y tres alérgenos; queda en el catálogo y sin cambios pendientes', () async {
      await start();
      final editor = open(create)
        ..setNameIt('  Polpette al sugo ')
        ..toggleAllergen(Allergen.milk)
        ..toggleAllergen(Allergen.gluten)
        ..toggleAllergen(Allergen.eggs);

      expect(await editor.save(), RecipeSaveResult.saved);

      const expected = Recipe(
        id: _id1,
        nameIt: 'Polpette al sugo',
        allergens: [Allergen.gluten, Allergen.eggs, Allergen.milk],
      );
      expect(repository.saveCalls, [expected]);
      expect(inCatalog(_id1), expected);
      expect(stateOf(create).dirty, isFalse);
      expect(stateOf(create).saving, isFalse);
    });

    test('si falla: avisa, no pierde nada y el reintento manda el mismo id', () async {
      await start();
      repository.saveFailure = RecipesFailureKind.unavailable;
      final editor = open(create)..setNameIt('Polpette al sugo');

      expect(await editor.save(), RecipeSaveResult.failed);
      expect(stateOf(create).saveError, RecipesFailureKind.unavailable);
      expect(stateOf(create).draft.nameIt, 'Polpette al sugo');
      expect(stateOf(create).dirty, isTrue);

      repository.saveFailure = null;
      expect(await editor.save(), RecipeSaveResult.saved);
      expect(stateOf(create).saveError, isNull);
      expect(repository.saveCalls.map((r) => r.id), [_id1, _id1]);
      expect(repository.recipes.keys.where((id) => id == _id1), hasLength(1));
    });

    test('mientras guarda, otro toque no manda nada', () async {
      await start();
      repository.pendingSave = Completer<void>();
      final editor = open(create)..setNameIt('Polpette al sugo');

      final first = editor.save();
      await pumpEventQueue();
      expect(stateOf(create).saving, isTrue);
      expect(await editor.save(), RecipeSaveResult.busy);

      repository.pendingSave!.complete();
      expect(await first, RecipeSaveResult.saved);
      expect(repository.saveCalls, hasLength(1));
    });

    test('editar: manda el plato cambiado', () async {
      await start();
      final editor = open(editLasagne)..setNameIt('Lasagne verdi');
      expect(stateOf(editLasagne).dirty, isTrue);

      expect(await editor.save(), RecipeSaveResult.saved);
      expect(repository.saveCalls.single, lasagne().copyWith(nameIt: 'Lasagne verdi'));
      expect(stateOf(editLasagne).dirty, isFalse);
    });

    test('la descripción: se manda recortada y la que se vació va en null', () async {
      await start();
      final editor = open(editLasagne)
        ..setDescriptionIt('  Ragù di manzo e maiale,   besciamella. ')
        ..setDescriptionEs('   ')
        ..setDescriptionEn('Beef and pork ragù.');
      expect(await editor.save(), RecipeSaveResult.saved);

      final saved = repository.saveCalls.single;
      expect(saved.descriptionIt, 'Ragù di manzo e maiale, besciamella.');
      expect(saved.descriptionEs, isNull);
      expect(saved.descriptionEn, 'Beef and pork ragù.');
      expect(inCatalog(lasagneId)!.descriptionIt, 'Ragù di manzo e maiale, besciamella.');
    });

    test('una descripción de más de 200 caracteres no deja guardar', () async {
      await start();
      final editor = open(editLasagne)..setDescriptionIt('d' * 201);
      expect(await editor.save(), RecipeSaveResult.invalid);
      expect(stateOf(editLasagne).errors.descriptionIt, TextError.tooLong);
      expect(repository.saveCalls, isEmpty);
    });

    test('guardar uno desactivado no lo reactiva', () async {
      await start();
      final editor = open(editFrittata)..setNameIt('Frittata di zucchine e menta');
      expect(await editor.save(), RecipeSaveResult.saved);
      expect(inCatalog(frittataId)!.active, isFalse);
      expect(repository.recipes[frittataId]!.active, isFalse);
    });

    test('la copia se guarda como un plato nuevo, sin las descripciones de la web, y el original no cambia', () async {
      await start();
      final editor = open(copyLasagne)..setNameIt('Lasagne vegetariane');
      expect(await editor.save(), RecipeSaveResult.saved);

      expect(
        inCatalog(_id1),
        lasagne().copyWith(id: _id1, nameIt: 'Lasagne vegetariane', descriptionIt: null, descriptionEs: null),
      );
      expect(inCatalog(_id1)!.webStatus, RecipeWebStatus.missingDescription);
      expect(inCatalog(lasagneId), lasagne());
    });

    // save_recipe no recibe active: el plato nuevo nace activo en la base, y
    // la lista tiene que decir lo mismo (no heredar el estado del original).
    test('la copia de un plato desactivado sale activa, en la lista y en el servidor', () async {
      await start();
      const copyFrittata = RecipeEditorTarget.copy(frittataId);
      final editor = open(copyFrittata)..setNameIt('Frittata di zucchine e menta');
      expect(await editor.save(), RecipeSaveResult.saved);

      expect(inCatalog(_id1)!.active, isTrue);
      expect(repository.recipes[_id1]!.active, isTrue);
      expect(stateOf(copyFrittata).source!.active, isTrue);
      expect(inCatalog(frittataId)!.active, isFalse, reason: 'el original sigue desactivado');
    });
  });

  group('desactivar y reactivar', () {
    test('desactiva por el catálogo y avisa mientras espera', () async {
      await start();
      repository.pendingSetActive = Completer<void>();
      final editor = open(editLasagne);

      final done = editor.setActive(active: false);
      await pumpEventQueue();
      expect(stateOf(editLasagne).changingActive, isTrue);
      expect(inCatalog(lasagneId)!.active, isFalse);

      repository.pendingSetActive!.complete();
      await done;
      expect(stateOf(editLasagne).changingActive, isFalse);
      expect(repository.setActiveCalls, [(id: lasagneId, active: false)]);
    });

    test('si falla, relanza y el plato vuelve a estar activo', () async {
      await start();
      repository.failSetActive = true;
      final editor = open(editLasagne);
      await expectLater(editor.setActive(active: false), throwsA(isA<RecipesFailure>()));
      expect(stateOf(editLasagne).changingActive, isFalse);
      expect(inCatalog(lasagneId)!.active, isTrue);
    });

    test('un plato nuevo no se desactiva (todavía no existe)', () async {
      await start();
      await open(create).setActive(active: false);
      expect(repository.setActiveCalls, isEmpty);
    });
  });

  test('aviso de nombre repetido: la copia tiene el mismo nombre hasta cambiarlo', () async {
    await start();
    final editor = open(copyLasagne);
    container.listen(recipeNameTakenProvider(copyLasagne), (_, _) {});
    expect(container.read(recipeNameTakenProvider(copyLasagne)), isTrue);
    editor.setNameIt('Lasagne vegetariane');
    expect(container.read(recipeNameTakenProvider(copyLasagne)), isFalse);

    open(editLasagne);
    container.listen(recipeNameTakenProvider(editLasagne), (_, _) {});
    expect(container.read(recipeNameTakenProvider(editLasagne)), isFalse, reason: 'su propio nombre');
  });
}

// Editor de un plato: nuevo, guardado o copia; los chips de alérgenos, dieta
// y meses; las filas de ingredientes (agregar, mover, quitar y deshacer); el
// guardado con el mismo id en cada reintento; la traducción automática al
// guardar (qué se traduce, la falla del traductor, el reintento y guardar
// sin traducir), y desactivar o reactivar.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/application/recipe_editor_controller.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/domain/recipe_translation.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

const String _id1 = '0e5b3c1a-2f4d-4a6b-8c9d-000000000001';
const String _id2 = '0e5b3c1a-2f4d-4a6b-8c9d-000000000002';

void main() {
  late FakeRecipesRepository repository;
  late FakeTranslationRepository translator;
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
        translationRepositoryProvider.overrideWithValue(translator),
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
    repository = FakeRecipesRepository([...sampleRecipes(), milanesa()]);
    translator = FakeTranslationRepository();
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
      expect(stateOf(create).errors.nameEs, TextError.required);
      expect(repository.saveCalls, isEmpty);
    });

    test('alta rápida: nombre en español y tres alérgenos; queda en el catálogo y sin cambios pendientes', () async {
      await start();
      final editor = open(create)
        ..setNameEs('  Albóndigas con salsa ')
        ..toggleAllergen(Allergen.milk)
        ..toggleAllergen(Allergen.gluten)
        ..toggleAllergen(Allergen.eggs);

      expect(await editor.save(), RecipeSaveResult.saved);

      const expected = Recipe(
        id: _id1,
        nameIt: '[it] Albóndigas con salsa',
        nameEs: 'Albóndigas con salsa',
        nameEn: '[en] Albóndigas con salsa',
        autoTranslated: {TranslatedField.nameIt, TranslatedField.nameEn},
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
      final editor = open(create)
        ..setNameEs('Albóndigas con salsa')
        ..setNameIt('Polpette al sugo');

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
      final editor = open(create)..setNameEs('Albóndigas con salsa');

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
      final editor = open(editLasagne)
        ..setNameIt('Lasagne verdi')
        ..setDescriptionEn('Slow-cooked ragù.');
      expect(stateOf(editLasagne).dirty, isTrue);

      expect(await editor.save(), RecipeSaveResult.saved);
      expect(
        repository.saveCalls.single,
        lasagne().copyWith(nameIt: 'Lasagne verdi', descriptionEn: 'Slow-cooked ragù.'),
      );
      expect(translator.calls, isEmpty, reason: 'todo escrito a mano y sin campos vacíos');
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

  // El español es la fuente (SPEC §4): al guardar se traduce lo vacío y lo
  // automático cuyo español cambió; lo escrito a mano nunca se pisa.
  group('la traducción al guardar', () {
    const editMilanesa = RecipeEditorTarget.edit(milanesaId);
    const SpanishText milanesaSpanish = (
      name: 'Milanesa a la napolitana',
      description: 'Con salsa de tomate, jamón y mozzarella.',
    );

    test('uno nuevo: traduce el nombre y la descripción y guarda los cuatro como automáticos', () async {
      await start();
      final editor = open(create)
        ..setNameEs('  Milanesa a la napolitana ')
        ..setDescriptionEs('Con salsa de tomate, jamón y mozzarella.')
        ..toggleAllergen(Allergen.gluten);
      expect(stateOf(create).errors.isEmpty, isTrue, reason: 'el italiano sale del español');

      expect(await editor.save(), RecipeSaveResult.saved);

      expect(translator.calls, [milanesaSpanish]);
      const expected = Recipe(
        id: _id1,
        nameIt: '[it] Milanesa a la napolitana',
        nameEs: 'Milanesa a la napolitana',
        nameEn: '[en] Milanesa a la napolitana',
        descriptionIt: '[it] Con salsa de tomate, jamón y mozzarella.',
        descriptionEs: 'Con salsa de tomate, jamón y mozzarella.',
        descriptionEn: '[en] Con salsa de tomate, jamón y mozzarella.',
        autoTranslated: {
          TranslatedField.nameIt,
          TranslatedField.descriptionIt,
          TranslatedField.nameEn,
          TranslatedField.descriptionEn,
        },
        allergens: [Allergen.gluten],
      );
      expect(repository.saveCalls, [expected]);
      expect(inCatalog(_id1), expected);
      // Con la descripción en español alcanza para salir en la web.
      expect(inCatalog(_id1)!.webStatus, RecipeWebStatus.published);
      expect(stateOf(create).draft.nameIt, '[it] Milanesa a la napolitana', reason: 'el formulario muestra lo traducido');
      expect(stateOf(create).translating, isFalse);
      expect(stateOf(create).dirty, isFalse);
    });

    test('uno nuevo sin el nombre en español: no traduce ni guarda y lo marca', () async {
      await start();
      final editor = open(create)..setDescriptionEs('Con salsa de tomate.');
      expect(await editor.save(), RecipeSaveResult.invalid);
      expect(stateOf(create).errors.nameEs, TextError.required);
      expect(stateOf(create).errors.nameIt, isNull, reason: 'falta el español, no el italiano');
      expect(translator.calls, isEmpty);
      expect(repository.saveCalls, isEmpty);
    });

    test('uno viejo sin español se guarda como está, sin traducir', () async {
      final old = lasagne().copyWith(id: _id2, nameEs: null, descriptionEs: null);
      repository.recipes[_id2] = old;
      await start();
      const editOld = RecipeEditorTarget.edit(_id2);
      final editor = open(editOld)..toggleAllergen(Allergen.sesame);
      expect(stateOf(editOld).spanishRequired, isFalse);

      expect(await editor.save(), RecipeSaveResult.saved);
      expect(translator.calls, isEmpty);
      expect(repository.saveCalls.single, old.copyWith(allergens: [...old.allergens, Allergen.sesame]));
    });

    test('uno viejo sin nombre en español pero con una descripción que traducir: pide el nombre', () async {
      final old = lasagne().copyWith(id: _id2, nameEs: null);
      repository.recipes[_id2] = old;
      await start();
      const editOld = RecipeEditorTarget.edit(_id2);
      final editor = open(editOld)..toggleAllergen(Allergen.sesame);

      expect(await editor.save(), RecipeSaveResult.invalid);
      expect(stateOf(editOld).errors.nameEs, TextError.required);
      expect(stateOf(editOld).errors.spanishNameToTranslate, isTrue);
      expect(translator.calls, isEmpty);
      expect(repository.saveCalls, isEmpty);

      editor.setNameEs('Lasaña a la boloñesa');
      expect(await editor.save(), RecipeSaveResult.saved);
      expect(repository.saveCalls.single.descriptionEn, '[en] $lasagneDescriptionEs');
    });

    test('sin descripción que traducir, a Anthropic no va la descripción', () async {
      await start();
      final editor = open(editMilanesa)..setNameEs('Napolitana');
      expect(await editor.save(), RecipeSaveResult.saved);
      expect(translator.calls, [(name: 'Napolitana', description: null)]);
      expect(repository.saveCalls.single.descriptionIt, milanesa().descriptionIt);
    });

    test('uno que ya tenía español no lo puede perder', () async {
      await start();
      final editor = open(editLasagne)..setNameEs(' ');
      expect(await editor.save(), RecipeSaveResult.invalid);
      expect(stateOf(editLasagne).errors.nameEs, TextError.required);
      expect(repository.saveCalls, isEmpty);
    });

    test('uno escrito a mano: traduce lo vacío y no toca lo demás', () async {
      await start();
      // La lasaña no tiene la descripción en inglés.
      final editor = open(editLasagne)..setNameEs('Lasaña boloñesa');
      expect(await editor.save(), RecipeSaveResult.saved);

      expect(translator.calls, [(name: 'Lasaña boloñesa', description: lasagneDescriptionEs)]);
      expect(
        repository.saveCalls.single,
        lasagne().copyWith(
          nameEs: 'Lasaña boloñesa',
          descriptionEn: '[en] $lasagneDescriptionEs',
          autoTranslated: {TranslatedField.descriptionEn},
        ),
      );
    });

    test('con campos automáticos y el español sin cambios: no traduce y guarda las marcas', () async {
      await start();
      final editor = open(editMilanesa)..toggleAllergen(Allergen.mustard);
      expect(await editor.save(), RecipeSaveResult.saved);
      expect(translator.calls, isEmpty);
      expect(repository.saveCalls.single.autoTranslated, milanesa().autoTranslated);
    });

    test('cambió la descripción en español: traduce las descripciones automáticas, el resto queda', () async {
      await start();
      final editor = open(editMilanesa)..setDescriptionEs('Con tomate y queso.');
      expect(await editor.save(), RecipeSaveResult.saved);

      expect(translator.calls, [(name: 'Milanesa a la napolitana', description: 'Con tomate y queso.')]);
      expect(
        repository.saveCalls.single,
        milanesa().copyWith(
          descriptionEs: 'Con tomate y queso.',
          descriptionIt: '[it] Con tomate y queso.',
          descriptionEn: '[en] Con tomate y queso.',
        ),
      );
    });

    test('se borró la descripción en español: las automáticas se vacían sin llamar al traductor', () async {
      await start();
      final editor = open(editMilanesa)..setDescriptionEs('');
      expect(await editor.save(), RecipeSaveResult.saved);

      expect(translator.calls, isEmpty);
      final saved = repository.saveCalls.single;
      expect([saved.descriptionEs, saved.descriptionIt, saved.descriptionEn], [null, null, null]);
      expect(saved.autoTranslated, {TranslatedField.nameEn});
      expect(stateOf(editMilanesa).draft.descriptionIt, isEmpty);
    });

    test('tocar un campo a mano lo saca de los automáticos y no se vuelve a traducir', () async {
      await start();
      final editor = open(editMilanesa)..setNameEn('Milanese Neapolitan style');
      expect(stateOf(editMilanesa).draft.autoTranslated, {
        TranslatedField.descriptionIt,
        TranslatedField.descriptionEn,
      });

      editor.setNameEs('Napolitana');
      expect(await editor.save(), RecipeSaveResult.saved);
      expect(translator.calls, isEmpty, reason: 'los dos nombres están escritos a mano');
      expect(repository.saveCalls.single.nameEn, 'Milanese Neapolitan style');
      expect(repository.saveCalls.single.autoTranslated, {
        TranslatedField.descriptionIt,
        TranslatedField.descriptionEn,
      });
    });

    test('mientras traduce lo dice, y otro toque no manda nada', () async {
      await start();
      translator.pending = Completer<void>();
      final editor = open(create)..setNameEs('Locro');

      final first = editor.save();
      await pumpEventQueue();
      expect(stateOf(create).translating, isTrue);
      expect(stateOf(create).busy, isTrue);
      expect(await editor.save(), RecipeSaveResult.busy);
      expect(await editor.saveWithoutTranslating(), RecipeSaveResult.busy);

      translator.pending!.complete();
      expect(await first, RecipeSaveResult.saved);
      expect(translator.calls, hasLength(1));
      expect(repository.saveCalls, hasLength(1));
      expect(stateOf(create).translating, isFalse);
    });

    for (final kind in TranslationFailureKind.values) {
      test('si el traductor falla (${kind.name}): no guarda nada y lo escrito queda', () async {
        await start();
        translator.failure = kind;
        final editor = open(editMilanesa)
          ..setNameEs('Napolitana')
          ..setNameIt('Cotoletta');
        final before = stateOf(editMilanesa).draft;

        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(stateOf(editMilanesa).translateError, kind);
        expect(stateOf(editMilanesa).translating, isFalse);
        expect(stateOf(editMilanesa).draft, before, reason: 'ni lo escrito ni las marcas cambian');
        expect(repository.saveCalls, isEmpty);
        expect(inCatalog(milanesaId), milanesa());
      });
    }

    test('el reintento traduce de nuevo y guarda con el mismo id', () async {
      await start();
      translator.failure = TranslationFailureKind.timeout;
      final editor = open(create)..setNameEs('Locro');
      expect(await editor.save(), RecipeSaveResult.translationFailed);

      translator.failure = null;
      expect(await editor.save(), RecipeSaveResult.saved);
      expect(stateOf(create).translateError, isNull);
      expect(translator.calls, [(name: 'Locro', description: null), (name: 'Locro', description: null)]);
      expect(repository.saveCalls.single.id, _id1);
      expect(repository.saveCalls.single.nameIt, '[it] Locro');
    });

    test('si la traducción llegó pero save_recipe falló, el reintento no vuelve a traducir', () async {
      await start();
      repository.saveFailure = RecipesFailureKind.unavailable;
      final editor = open(create)..setNameEs('Locro');
      expect(await editor.save(), RecipeSaveResult.failed);
      expect(stateOf(create).draft.nameIt, '[it] Locro', reason: 'lo traducido queda en el formulario');
      expect(stateOf(create).dirty, isTrue);

      repository.saveFailure = null;
      expect(await editor.save(), RecipeSaveResult.saved);
      expect(translator.calls, hasLength(1));
      expect(repository.saveCalls.map((r) => r.id), [_id1, _id1]);
      expect(repository.saveCalls.last.autoTranslated, {TranslatedField.nameIt, TranslatedField.nameEn});
    });

    test('«Annulla» de un ingrediente quitado no hace nada mientras traduce', () async {
      await start();
      translator.pending = Completer<void>();
      final editor = open(editLasagne);
      final removed = editor.removeIngredient(stateOf(editLasagne).draft.ingredients.first.key)!;
      final saving = editor.save();
      await pumpEventQueue();
      expect(stateOf(editLasagne).translating, isTrue);

      editor.restoreIngredient(removed);
      expect(stateOf(editLasagne).draft.ingredients, hasLength(2), reason: 'quedaría fuera del guardado');

      translator.pending!.complete();
      expect(await saving, RecipeSaveResult.saved);
      expect(repository.saveCalls.single.ingredients, hasLength(2));
    });

    test('si el formulario cambió mientras traducía, la traducción no pisa nada ni se guarda', () async {
      await start();
      translator.pending = Completer<void>();
      final editor = open(create)..setNameEs('Locro');
      final saving = editor.save();
      await pumpEventQueue();
      editor.setNameIt('Locro criollo');

      translator.pending!.complete();
      expect(await saving, RecipeSaveResult.stale);
      expect(stateOf(create).draft.nameIt, 'Locro criollo');
      expect(stateOf(create).translating, isFalse);
      expect(repository.saveCalls, isEmpty);
    });

    // Decisión del 20/11/2026: con la traducción apagada (501) y solo campos
    // vacíos para traducir no queda nada viejo, así que guarda sin traducir
    // y la lista lo dice; si algo automático quedaría viejo, o falta el
    // nombre en italiano, sigue el aviso con las salidas.
    group('con la traducción apagada', () {
      test('y solo campos vacíos para traducir: guarda sin traducir', () async {
        await start();
        translator.failure = TranslationFailureKind.notConfigured;
        // La lasaña no tiene la descripción en inglés.
        final editor = open(editLasagne)..toggleAllergen(Allergen.sesame);

        expect(await editor.save(), RecipeSaveResult.savedUntranslated);
        expect(translator.calls, hasLength(1));
        expect(repository.saveCalls.single, lasagne().copyWith(allergens: [...lasagne().allergens, Allergen.sesame]));
        expect(stateOf(editLasagne).translateError, isNull);
        expect(stateOf(editLasagne).translating, isFalse);
        expect(stateOf(editLasagne).dirty, isFalse);
      });

      test('un plato nuevo con el italiano escrito a mano: guarda sin traducir el inglés', () async {
        await start();
        translator.failure = TranslationFailureKind.notConfigured;
        final editor = open(create)
          ..setNameEs('Locro')
          ..setNameIt('Locro');
        expect(await editor.save(), RecipeSaveResult.savedUntranslated);
        expect(repository.saveCalls.single, const Recipe(id: _id1, nameIt: 'Locro', nameEs: 'Locro'));
      });

      test('si algo automático quedaría viejo, no guarda y sigue el aviso', () async {
        await start();
        translator.failure = TranslationFailureKind.notConfigured;
        final editor = open(editMilanesa)..setDescriptionEs('Con tomate y queso.');
        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(stateOf(editMilanesa).translateError, TranslationFailureKind.notConfigured);
        expect(repository.saveCalls, isEmpty);
      });

      test('un plato nuevo sin el nombre en italiano tampoco: sigue el aviso', () async {
        await start();
        translator.failure = TranslationFailureKind.notConfigured;
        final editor = open(create)..setNameEs('Locro');
        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(repository.saveCalls, isEmpty);
      });

      test('con otra falla y solo campos vacíos, no guarda: sigue el aviso', () async {
        await start();
        translator.failure = TranslationFailureKind.unavailable;
        final editor = open(editLasagne)..toggleAllergen(Allergen.sesame);
        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(repository.saveCalls, isEmpty);
      });

      test('si save_recipe falla, lo dice como cualquier guardado y no se pierde nada', () async {
        await start();
        translator.failure = TranslationFailureKind.notConfigured;
        repository.saveFailure = RecipesFailureKind.unavailable;
        final editor = open(editLasagne)..toggleAllergen(Allergen.sesame);
        expect(await editor.save(), RecipeSaveResult.failed);
        expect(stateOf(editLasagne).saveError, RecipesFailureKind.unavailable);
        expect(stateOf(editLasagne).draft.allergens, contains(Allergen.sesame));
      });
    });

    // Revisión del 20/11/2026: un 422 o un 429 no se arregla reintentando lo
    // mismo (y el 429 rechazado gasta cupo); con el mismo pedido no se vuelve
    // a llamar. El 422 con solo campos vacíos guarda sin traducir, como el
    // 501.
    group('las negativas que no se arreglan reintentando', () {
      for (final kind in const [TranslationFailureKind.untranslatable, TranslationFailureKind.rateLimited]) {
        test('${kind.name}: con el mismo español va directo al aviso, sin llamar; con otro, llama', () async {
          await start();
          translator.failure = kind;
          final editor = open(editMilanesa)..setDescriptionEs('Con tomate y queso.');
          expect(await editor.save(), RecipeSaveResult.translationFailed);
          expect(stateOf(editMilanesa).refusal, (
            kind: kind,
            request: (name: 'Milanesa a la napolitana', description: 'Con tomate y queso.'),
          ));

          expect(await editor.save(), RecipeSaveResult.translationFailed);
          expect(stateOf(editMilanesa).translateError, kind);
          expect(translator.calls, hasLength(1), reason: 'el mismo pedido no vuelve a la red');

          translator.failure = null;
          editor.setDescriptionEs('Con tomate, jamón y queso.');
          expect(await editor.save(), RecipeSaveResult.saved);
          expect(translator.calls, hasLength(2));
          expect(stateOf(editMilanesa).refusal, isNull);
        });
      }

      test('un 503 no queda guardado: el reintento vuelve a llamar', () async {
        await start();
        translator.failure = TranslationFailureKind.unavailable;
        final editor = open(editMilanesa)..setDescriptionEs('Con tomate y queso.');
        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(stateOf(editMilanesa).refusal, isNull);
        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(translator.calls, hasLength(2));
      });

      test('un 422 con solo campos vacíos guarda sin traducir y dice por qué', () async {
        await start();
        translator.failure = TranslationFailureKind.untranslatable;
        // La lasaña no tiene la descripción en inglés.
        final editor = open(editLasagne)..toggleAllergen(Allergen.sesame);
        expect(await editor.save(), RecipeSaveResult.savedUntranslated);
        expect(stateOf(editLasagne).untranslatedBecause, TranslationFailureKind.untranslatable);
        expect(repository.saveCalls.single.descriptionEn, isNull);
      });

      test('un 429 con solo campos vacíos no guarda: sigue el aviso', () async {
        await start();
        translator.failure = TranslationFailureKind.rateLimited;
        final editor = open(editLasagne)..toggleAllergen(Allergen.sesame);
        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(repository.saveCalls, isEmpty);
      });

      test('después de un guardado normal, el motivo de guardar sin traducir no queda', () async {
        await start();
        translator.failure = TranslationFailureKind.notConfigured;
        final editor = open(editLasagne)..toggleAllergen(Allergen.sesame);
        expect(await editor.save(), RecipeSaveResult.savedUntranslated);
        expect(stateOf(editLasagne).untranslatedBecause, TranslationFailureKind.notConfigured);
        translator.failure = null;
        expect(await editor.save(), RecipeSaveResult.saved);
        expect(stateOf(editLasagne).untranslatedBecause, isNull);
      });
    });

    group('guardar sin traducir', () {
      test('lo automático viejo se vacía, lo escrito a mano queda y el español se guarda', () async {
        await start();
        translator.failure = TranslationFailureKind.unavailable;
        final editor = open(editMilanesa)
          ..setNameEs('Napolitana')
          ..setDescriptionEs('Con tomate.');
        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(stateOf(editMilanesa).translationPlan.canSkip, isTrue);

        expect(await editor.saveWithoutTranslating(), RecipeSaveResult.saved);
        expect(translator.calls, hasLength(1), reason: 'no vuelve a llamar');
        final saved = repository.saveCalls.single;
        expect(saved.nameIt, 'Cotoletta alla napoletana');
        expect([saved.nameEs, saved.descriptionEs], ['Napolitana', 'Con tomate.']);
        expect([saved.descriptionIt, saved.nameEn, saved.descriptionEn], [null, null, null]);
        expect(saved.autoTranslated, isEmpty);
        expect(stateOf(editMilanesa).translateError, isNull);
        expect(stateOf(editMilanesa).draft.nameEn, isEmpty, reason: 'el formulario muestra lo que se guardó');
      });

      test('uno nuevo sin el nombre en italiano no se puede; escribiéndolo, sí', () async {
        await start();
        translator.failure = TranslationFailureKind.notConfigured;
        final editor = open(create)..setNameEs('Locro');
        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(stateOf(create).translationPlan.canSkip, isFalse);
        expect(await editor.saveWithoutTranslating(), RecipeSaveResult.invalid);
        expect(repository.saveCalls, isEmpty);

        editor.setNameIt('Locro');
        expect(stateOf(create).translationPlan.canSkip, isTrue);
        expect(await editor.saveWithoutTranslating(), RecipeSaveResult.saved);
        expect(repository.saveCalls.single, const Recipe(id: _id1, nameIt: 'Locro', nameEs: 'Locro'));
        expect(translator.calls, hasLength(1));
      });

      test('después de guardar sin traducir, lo vacío se traduce la próxima vez', () async {
        await start();
        translator.failure = TranslationFailureKind.timeout;
        final editor = open(create)
          ..setNameEs('Locro')
          ..setNameIt('Locro');
        expect(await editor.save(), RecipeSaveResult.translationFailed);
        expect(await editor.saveWithoutTranslating(), RecipeSaveResult.saved);

        translator.failure = null;
        expect(await editor.save(), RecipeSaveResult.saved);
        expect(repository.saveCalls.last.nameEn, '[en] Locro');
        expect(repository.saveCalls.last.nameIt, 'Locro', reason: 'escrito a mano');
      });
    });

    // SPEC §4: duplicar no copia las descripciones de la web, así que
    // tampoco sus marcas; las de los nombres copiados, sí.
    test('la copia lleva las marcas de los nombres; si cambia el español, se traduce el automático', () async {
      await start();
      const copyMilanesa = RecipeEditorTarget.copy(milanesaId);
      final editor = open(copyMilanesa);
      expect(stateOf(copyMilanesa).draft.autoTranslated, {TranslatedField.nameEn});
      expect(stateOf(copyMilanesa).spanishRequired, isTrue);

      editor.setNameEs('Milanesa de pollo');
      expect(await editor.save(), RecipeSaveResult.saved);
      expect(translator.calls, [(name: 'Milanesa de pollo', description: null)]);
      final saved = repository.saveCalls.single;
      expect(saved.id, _id1);
      expect(saved.nameIt, 'Cotoletta alla napoletana', reason: 'escrito a mano en el original');
      expect(saved.nameEn, '[en] Milanesa de pollo');
      expect([saved.descriptionIt, saved.descriptionEs, saved.descriptionEn], [null, null, null]);
      expect(saved.autoTranslated, {TranslatedField.nameEn});
      expect(inCatalog(milanesaId), milanesa(), reason: 'el original no cambia');
    });

    test('el aviso de nombre repetido no sale si el italiano automático se va a traducir de nuevo', () async {
      final auto = milanesa().copyWith(
        autoTranslated: {...milanesa().autoTranslated, TranslatedField.nameIt},
      );
      repository.recipes[milanesaId] = auto;
      await start();
      const copyMilanesa = RecipeEditorTarget.copy(milanesaId);
      final editor = open(copyMilanesa);
      container.listen(recipeNameTakenProvider(copyMilanesa), (_, _) {});
      expect(container.read(recipeNameTakenProvider(copyMilanesa)), isTrue);
      editor.setNameEs('Milanesa de pollo');
      expect(container.read(recipeNameTakenProvider(copyMilanesa)), isFalse);
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

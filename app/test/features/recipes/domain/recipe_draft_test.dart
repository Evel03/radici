// El formulario de un plato, en Dart puro: cómo se arma desde un plato
// guardado o una copia, qué se valida (lo mismo que los checks de la base, más
// la dieta contra los alérgenos) y el plato que sale para save_recipe.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/recipe_fixtures.dart';

const String _newId = '0e5b3c1a-2f4d-4a6b-8c9d-0123456789ab';

RecipeDraft _valid({String nameIt = 'Pasta al pesto', List<IngredientDraft> ingredients = const []}) =>
    emptyRecipeDraft(_newId).copyWith(nameIt: nameIt, ingredients: ingredients);

IngredientDraft _row(
  int key, {
  String name = 'Basilico',
  String quantity = '50',
  UnitChoice unit = UnitChoice.g,
  ShoppingSection section = ShoppingSection.produce,
}) => IngredientDraft(key: key, name: name, quantity: quantity, unit: unit, section: section);

void main() {
  group('borrador', () {
    test('uno nuevo: vacío, con la conservación por defecto de la base', () {
      final draft = emptyRecipeDraft(_newId);
      expect(draft.id, _newId);
      expect(draft.nameIt, '');
      expect(draft.allergens, isEmpty);
      expect(draft.diet, isNull);
      expect(draft.months, isEmpty, reason: 'vacío = todo el año');
      expect(draft.fridgeDays, '3');
      expect(draft.freezable, isFalse);
      expect(draft.freezerDays, '60');
      expect(draft.ingredients, isEmpty);
    });

    test('desde un plato guardado: todo como texto y una clave por ingrediente', () {
      final draft = recipeDraftFrom(lasagne());
      expect(draft.id, lasagneId);
      expect(draft.nameIt, 'Lasagne alla bolognese');
      expect(draft.nameEs, 'Lasaña a la boloñesa');
      expect(draft.nameEn, 'Lasagne Bolognese');
      expect(draft.descriptionIt, 'Ragù cotto piano e besciamella fatta in casa.');
      expect(draft.descriptionEs, 'Ragú cocido despacio y bechamel casera.');
      expect(draft.descriptionEn, '', reason: 'sin descripción, el campo vacío');
      expect(draft.allergens, {Allergen.gluten, Allergen.eggs, Allergen.milk, Allergen.celery});
      expect(draft.freezable, isTrue);
      expect(draft.ingredients, [
        const IngredientDraft(
          key: 0,
          name: 'Carne macinata di manzo',
          quantity: '400',
          section: ShoppingSection.meatFish,
        ),
        const IngredientDraft(
          key: 1,
          name: 'Passata di pomodoro',
          quantity: '700',
          unit: UnitChoice.ml,
          section: ShoppingSection.pantry,
        ),
        const IngredientDraft(key: 2, name: 'Sale', unit: UnitChoice.toTaste, section: ShoppingSection.pantry),
      ]);

      final risottoDraft = recipeDraftFrom(risotto());
      expect(risottoDraft.months, {9, 10, 11});
      expect(risottoDraft.diet, Diet.vegetarian);
      expect(risottoDraft.fridgeDays, '2');
      expect(risottoDraft.notes, 'Si può fare senza burro e parmigiano.');
    });

    // La copia es otro plato: no sale en la web con la descripción del
    // original hasta que Evelyn le escriba la suya.
    test('una copia: todo igual menos el id, y sin las descripciones de la web', () {
      final copy = recipeDraftFrom(lasagne(), id: _newId);
      expect(copy.id, _newId);
      expect([copy.descriptionIt, copy.descriptionEs, copy.descriptionEn], ['', '', '']);
      expect(
        copy.copyWith(id: lasagneId, descriptionIt: lasagneDescriptionIt, descriptionEs: lasagneDescriptionEs),
        recipeDraftFrom(lasagne()),
      );
    });

    test('desde un plato guardado, con los campos de la traducción automática', () {
      expect(recipeDraftFrom(milanesa()).autoTranslated, milanesa().autoTranslated);
      expect(recipeDraftFrom(lasagne()).autoTranslated, isEmpty);
    });

    // SPEC §4: la copia no lleva las descripciones de la web, así que tampoco
    // sus marcas; los nombres copiados quedan como estaban.
    test('una copia lleva las marcas de los nombres, no las de las descripciones', () {
      final copy = recipeDraftFrom(milanesa(), id: _newId);
      expect(copy.autoTranslated, {TranslatedField.nameEn});
      expect([copy.nameIt, copy.nameEs, copy.nameEn], [milanesa().nameIt, milanesa().nameEs, milanesa().nameEn]);
    });

    // Decisión del 20/11/2026: Evelyn cargó los platos en español en el campo
    // italiano. Un plato guardado sin nombre en español se abre como si lo
    // escrito en italiano estuviera en español, y el italiano queda vacío
    // para traducir.
    test('un plato viejo (sin nombre en español): el italiano pasa al español', () {
      final draft = recipeDraftFrom(pastel());
      expect([draft.nameEs, draft.nameIt], ['Pastel de papa', '']);
      expect([draft.descriptionEs, draft.descriptionIt], [pastelDescription, '']);
      expect(italianMovedToSpanish(pastel()), {TranslatedField.nameIt, TranslatedField.descriptionIt});

      // Con la descripción en español, queda la suya y la italiana no se toca.
      final withSpanish = pastel().copyWith(descriptionEs: 'Pastel de carne y papa.');
      final kept = recipeDraftFrom(withSpanish);
      expect([kept.descriptionEs, kept.descriptionIt], ['Pastel de carne y papa.', pastelDescription]);
      expect(italianMovedToSpanish(withSpanish), {TranslatedField.nameIt});

      // La copia: el nombre, igual; las descripciones no se copian.
      final copy = recipeDraftFrom(pastel(), id: _newId);
      expect([copy.nameEs, copy.nameIt], ['Pastel de papa', '']);
      expect([copy.descriptionIt, copy.descriptionEs, copy.descriptionEn], ['', '', '']);
      expect(italianMovedToSpanish(pastel(), copy: true), {TranslatedField.nameIt});

      // Uno que ya tiene el nombre en español abre como está.
      expect(italianMovedToSpanish(lasagne()), isEmpty);
    });

    test('toString no muestra las notas (son de la cocinera)', () {
      final draft = recipeDraftFrom(risotto());
      expect(draft.toString(), 'RecipeDraft($risottoId)');
      expect('${[draft]}', isNot(contains('burro')));
    });
  });

  group('validación', () {
    test('con el nombre alcanza', () {
      expect(validateRecipeDraft(_valid()).isEmpty, isTrue);
    });

    test('el nombre en italiano es obligatorio y tiene hasta 120 caracteres', () {
      expect(validateRecipeDraft(_valid(nameIt: '   ')).nameIt, TextError.required);
      expect(validateRecipeDraft(_valid(nameIt: 'a' * 121)).nameIt, TextError.tooLong);
      expect(validateRecipeDraft(_valid(nameIt: ' ${'a' * 120} ')).nameIt, isNull);
      // Postgres cuenta caracteres: 120 emojis entran aunque en Dart midan 240.
      expect(validateRecipeDraft(_valid(nameIt: '🍝' * 120)).nameIt, isNull);
    });

    // Desde el 20/11/2026 el español es la fuente: el editor lo pide siempre
    // (un plato guardado abre con él); el italiano vacío se traduce de él.
    test('el nombre en español, obligatorio si el editor lo pide', () {
      final withoutSpanish = _valid();
      expect(validateRecipeDraft(withoutSpanish).nameEs, isNull, reason: 'las reglas de la base no lo piden');
      expect(validateRecipeDraft(withoutSpanish, requireSpanish: true).nameEs, TextError.required);
      expect(validateRecipeDraft(withoutSpanish.copyWith(nameEs: '  '), requireSpanish: true).nameEs, TextError.required);
      expect(validateRecipeDraft(withoutSpanish.copyWith(nameEs: 'Pasta'), requireSpanish: true).isEmpty, isTrue);
      expect(validateRecipeDraft(withoutSpanish.copyWith(nameEs: 'b' * 121), requireSpanish: true).nameEs, TextError.tooLong);
    });

    test('el nombre en italiano vacío no falta si se va a traducir del español', () {
      final onlySpanish = emptyRecipeDraft(_newId).copyWith(nameEs: 'Locro');
      expect(validateRecipeDraft(onlySpanish).nameIt, TextError.required, reason: 'la regla de la base');
      expect(validateRecipeDraft(onlySpanish, requireSpanish: true, willTranslate: true).isEmpty, isTrue);
      // Sin español no hay de dónde traducirlo.
      final nothing = emptyRecipeDraft(_newId);
      final errors = validateRecipeDraft(nothing, requireSpanish: true, willTranslate: true);
      expect(errors.nameEs, TextError.required);
      expect(errors.nameIt, isNull, reason: 'falta el español: el italiano sale de ahí');
      expect(
        validateRecipeDraft(nothing, willTranslate: true).nameIt,
        TextError.required,
        reason: 'sin español, si no es obligatorio, falta el italiano',
      );
      expect(validateRecipeDraft(onlySpanish.copyWith(nameIt: 'a' * 121), willTranslate: true).nameIt, TextError.tooLong);
    });

    test('las traducciones son opcionales, con el mismo largo', () {
      final draft = _valid().copyWith(nameEs: '   ', nameEn: 'b' * 121);
      final errors = validateRecipeDraft(draft);
      expect(errors.nameEs, isNull);
      expect(errors.nameEn, TextError.tooLong);
      expect(validateRecipeDraft(_valid().copyWith(nameEs: 'b' * 121)).nameEs, TextError.tooLong);
      expect(validateRecipeDraft(_valid().copyWith(nameEs: 'b' * 120)).isEmpty, isTrue);
    });

    // Como los nombres: se cuentan sin los espacios de los bordes y por
    // caracteres, como Postgres (recipes_description_*_valida).
    test('las descripciones son opcionales y tienen hasta 200 caracteres', () {
      final draft = _valid().copyWith(descriptionIt: '   ', descriptionEs: 'd' * 201, descriptionEn: ' ${'d' * 200} ');
      final errors = validateRecipeDraft(draft);
      expect(errors.descriptionIt, isNull);
      expect(errors.descriptionEs, TextError.tooLong);
      expect(errors.descriptionEn, isNull);
      expect(errors.isEmpty, isFalse);
      expect(validateRecipeDraft(_valid().copyWith(descriptionIt: 'd' * 201)).descriptionIt, TextError.tooLong);
      expect(validateRecipeDraft(_valid().copyWith(descriptionEn: 'd' * 201)).descriptionEn, TextError.tooLong);
      expect(validateRecipeDraft(_valid().copyWith(descriptionIt: '🍝' * 200)).isEmpty, isTrue);
    });

    test('las notas tienen hasta 500 caracteres', () {
      expect(validateRecipeDraft(_valid().copyWith(notes: 'n' * 500)).notes, isNull);
      expect(validateRecipeDraft(_valid().copyWith(notes: 'n' * 501)).notes, TextError.tooLong);
    });

    test('la dieta no puede chocar con los alérgenos', () {
      final draft = _valid().copyWith(diet: Diet.vegan, allergens: {Allergen.milk, Allergen.celery});
      final errors = validateRecipeDraft(draft);
      expect(errors.dietConflicts, [Allergen.milk]);
      expect(errors.isEmpty, isFalse);
    });

    test('días en la heladera: de 0 a 30', () {
      expect(validateRecipeDraft(_valid().copyWith(fridgeDays: '0')).fridgeDays, isFalse);
      expect(validateRecipeDraft(_valid().copyWith(fridgeDays: '30')).fridgeDays, isFalse);
      expect(validateRecipeDraft(_valid().copyWith(fridgeDays: '31')).fridgeDays, isTrue);
      expect(validateRecipeDraft(_valid().copyWith(fridgeDays: '')).fridgeDays, isTrue);
      expect(validateRecipeDraft(_valid().copyWith(fridgeDays: '2,5')).fridgeDays, isTrue);
    });

    test('días en el freezer: de 1 a 365, solo si se puede congelar', () {
      RecipeDraft frozen(String days) => _valid().copyWith(freezable: true, freezerDays: days);
      expect(validateRecipeDraft(frozen('1')).freezerDays, isFalse);
      expect(validateRecipeDraft(frozen('365')).freezerDays, isFalse);
      expect(validateRecipeDraft(frozen('0')).freezerDays, isTrue);
      expect(validateRecipeDraft(frozen('366')).freezerDays, isTrue);
      expect(validateRecipeDraft(frozen('')).freezerDays, isTrue);
      expect(validateRecipeDraft(_valid().copyWith(freezerDays: '')).freezerDays, isFalse);
    });

    group('ingredientes', () {
      RecipeDraftErrors errorsOf(IngredientDraft row) =>
          validateRecipeDraft(_valid(ingredients: [row]));

      test('una fila vacía no cuenta (ni se valida ni se guarda)', () {
        expect(errorsOf(_row(0, name: ' ', quantity: '')).isEmpty, isTrue);
      });

      test('nombre obligatorio si la fila tiene algo, y hasta 80 caracteres', () {
        expect(errorsOf(_row(0, name: '', quantity: '200')).ingredients[0]?.name, TextError.required);
        expect(errorsOf(_row(0, name: 'x' * 81)).ingredients[0]?.name, TextError.tooLong);
        expect(errorsOf(_row(0, name: 'x' * 80)).isEmpty, isTrue);
      });

      test('con unidad, la cantidad es obligatoria y va de 1 a 100000', () {
        expect(errorsOf(_row(0, quantity: '')).ingredients[0]?.quantity, QuantityError.required);
        expect(errorsOf(_row(0, quantity: '0')).ingredients[0]?.quantity, QuantityError.outOfRange);
        expect(errorsOf(_row(0, quantity: '100001')).ingredients[0]?.quantity, QuantityError.outOfRange);
        expect(errorsOf(_row(0, quantity: '100000')).isEmpty, isTrue);
        expect(errorsOf(_row(0, quantity: '1')).isEmpty, isTrue);
      });

      test('q.b. no lleva cantidad (si quedó escrita, se ignora)', () {
        expect(errorsOf(_row(0, quantity: '', unit: UnitChoice.toTaste)).isEmpty, isTrue);
        expect(errorsOf(_row(0, quantity: '200', unit: UnitChoice.toTaste)).isEmpty, isTrue);
      });

      test('los errores van por la clave de la fila', () {
        final errors = validateRecipeDraft(
          _valid(ingredients: [_row(7), _row(3, name: ''), _row(9, quantity: '')]),
        );
        expect(errors.ingredients.keys, unorderedEquals([3, 9]));
      });

      test('hasta 50 ingredientes (las filas vacías no cuentan)', () {
        final fifty = [for (var i = 0; i < 50; i++) _row(i)];
        expect(validateRecipeDraft(_valid(ingredients: fifty)).tooManyIngredients, isFalse);
        expect(
          validateRecipeDraft(
            _valid(ingredients: [...fifty, _row(50, name: '', quantity: '')]),
          ).tooManyIngredients,
          isFalse,
        );
        expect(
          validateRecipeDraft(_valid(ingredients: [...fifty, _row(50)])).tooManyIngredients,
          isTrue,
        );
      });
    });
  });

  group('recipeFromDraft', () {
    test('un plato nuevo: nombres limpios, sin traducciones vacías y activo', () {
      final draft = _valid(nameIt: '  Pasta   al pesto ').copyWith(
        nameEs: ' Pasta al pesto ',
        nameEn: '   ',
        allergens: {Allergen.nuts, Allergen.milk, Allergen.gluten},
        months: {6, 7, 8},
        fridgeDays: '02',
        notes: '  Senza aglio.  ',
        ingredients: [
          _row(4, name: ' Basilico ', quantity: '50'),
          _row(5, name: '', quantity: ''),
          _row(1, name: 'Pinoli', quantity: '030', section: ShoppingSection.pantry),
          _row(2, name: 'Sale', quantity: '9', unit: UnitChoice.toTaste, section: ShoppingSection.pantry),
        ],
      );

      expect(
        recipeFromDraft(draft),
        const Recipe(
          id: _newId,
          nameIt: 'Pasta al pesto',
          nameEs: 'Pasta al pesto',
          allergens: [Allergen.gluten, Allergen.milk, Allergen.nuts],
          seasonMonths: [6, 7, 8],
          fridgeDays: 2,
          notes: 'Senza aglio.',
          ingredients: [
            RecipeIngredient(
              name: 'Basilico',
              section: ShoppingSection.produce,
              amount: (quantity: 50, unit: IngredientUnit.g),
            ),
            RecipeIngredient(
              name: 'Pinoli',
              section: ShoppingSection.pantry,
              amount: (quantity: 30, unit: IngredientUnit.g),
            ),
            RecipeIngredient(name: 'Sale', section: ShoppingSection.pantry),
          ],
        ),
      );
    });

    test('las descripciones sin espacios de más; vacías, en null', () {
      final draft = _valid().copyWith(
        descriptionIt: '  Basilico   fresco,\tpinoli e\nparmigiano.  ',
        descriptionEs: '   ',
        descriptionEn: ' Fresh basil. ',
      );
      final recipe = recipeFromDraft(draft);
      expect(recipe.descriptionIt, 'Basilico fresco, pinoli e parmigiano.');
      expect(recipe.descriptionEs, isNull);
      expect(recipe.descriptionEn, 'Fresh basil.');
    });

    test('ida y vuelta: un plato guardado sale igual', () {
      for (final recipe in sampleRecipes()) {
        expect(recipeFromDraft(recipeDraftFrom(recipe), saved: recipe), recipe);
      }
    });

    test('los campos de la traducción automática pasan, salvo los que quedaron vacíos', () {
      expect(recipeFromDraft(recipeDraftFrom(milanesa())).autoTranslated, milanesa().autoTranslated);
      final cleared = recipeDraftFrom(milanesa()).copyWith(descriptionEn: '   ');
      expect(recipeFromDraft(cleared).autoTranslated, {TranslatedField.descriptionIt, TranslatedField.nameEn});
      // Ni una marca sin el español del que sale (save_recipe la rechaza).
      final withoutSpanish = recipeDraftFrom(milanesa()).copyWith(descriptionEs: ' ');
      expect(recipeFromDraft(withoutSpanish).autoTranslated, {TranslatedField.nameEn});
    });

    test('los 12 meses son todo el año', () {
      final draft = _valid().copyWith(months: {for (var m = 1; m <= 12; m++) m});
      expect(recipeFromDraft(draft).seasonMonths, isNull);
    });

    test('el estado lo pone el plato guardado: guardar no reactiva uno desactivado', () {
      final draft = recipeDraftFrom(frittata()).copyWith(nameIt: 'Frittata di zucchine e menta');
      expect(recipeFromDraft(draft, saved: frittata()).active, isFalse);
    });

    test('sin congelar, un número de freezer inválido no impide guardar: queda el guardado', () {
      final draft = recipeDraftFrom(minestrone()).copyWith(freezable: false, freezerDays: '');
      final recipe = recipeFromDraft(draft, saved: minestrone());
      expect(recipe.freezable, isFalse);
      expect(recipe.freezerDays, 90);
      expect(recipeFromDraft(_valid().copyWith(freezerDays: '')).freezerDays, 60);
    });

    test('con errores lanza ArgumentError', () {
      expect(() => recipeFromDraft(_valid(nameIt: '')), throwsArgumentError);
    });
  });
}

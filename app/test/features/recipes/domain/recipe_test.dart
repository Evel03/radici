// Catálogo de platos, en Dart puro: la fila de PostgREST, lo que se manda a
// save_recipe, los nombres, la temporada, la dieta contra los alérgenos, la
// búsqueda en los tres idiomas y el orden de la lista.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/recipe_fixtures.dart';

void main() {
  group('Recipe.fromJson', () {
    test('lee la fila entera: alérgenos en el orden del enum e ingredientes por posición', () {
      final recipe = Recipe.fromJson(recipeRow());

      expect(recipe, lasagne());
      expect(recipe.allergens, [Allergen.gluten, Allergen.eggs, Allergen.milk, Allergen.celery]);
      expect(recipe.ingredients.map((i) => i.name), [
        'Carne macinata di manzo',
        'Passata di pomodoro',
        'Sale',
      ]);
      expect(recipe.ingredients.last.amount, isNull, reason: 'sin cantidad ni unidad: q.b.');
      expect(recipe.ingredients.last.toTaste, isTrue);
      expect(recipe.seasonMonths, isNull, reason: 'null = todo el año');
    });

    test('dieta, meses (ordenados), conservación, notas y estado', () {
      final recipe = Recipe.fromJson(
        recipeRow(
          id: risottoId,
          diet: 'vegetarian',
          seasonMonths: [11, 9, 10],
          fridgeDays: 2,
          freezable: false,
          freezerDays: 45,
          notes: 'Si può fare senza burro.',
          active: false,
          allergens: const <Object>[],
          ingredients: const <Object>[],
        ),
      );
      expect(recipe.diet, Diet.vegetarian);
      expect(recipe.seasonMonths, [9, 10, 11]);
      expect(recipe.fridgeDays, 2);
      expect(recipe.freezable, isFalse);
      expect(recipe.freezerDays, 45);
      expect(recipe.notes, 'Si può fare senza burro.');
      expect(recipe.active, isFalse);
      expect(recipe.allergens, isEmpty);
      expect(recipe.ingredients, isEmpty);
    });

    test('las notas llegan de recipe_notes como lista de cero o una fila (o la fila sola)', () {
      expect(Recipe.fromJson(recipeRow(notes: 'Senza aglio.')).notes, 'Senza aglio.');
      expect(Recipe.fromJson(recipeRow(notes: const <Object>[])).notes, isNull, reason: 'sin notas, sin fila');
      expect(Recipe.fromJson(recipeRow(notes: const {'notes': 'Senza aglio.'})).notes, 'Senza aglio.');
      expect(Recipe.fromJson(recipeRow(notes: const {'notes': ''})).notes, isNull);
    });

    test('sin traducciones quedan en null; los 12 meses son «todo el año»', () {
      final recipe = Recipe.fromJson(
        recipeRow(nameEs: null, nameEn: null, seasonMonths: [for (var m = 1; m <= 12; m++) m]),
      );
      expect(recipe.nameEs, isNull);
      expect(recipe.nameEn, isNull);
      expect(recipe.seasonMonths, isNull);
    });

    test('las descripciones de la web en los tres idiomas; sin descripción (o vacía) queda en null', () {
      final recipe = Recipe.fromJson(recipeRow(descriptionEn: 'Slow-cooked ragù and homemade béchamel.'));
      expect(recipe.descriptionIt, 'Ragù cotto piano e besciamella fatta in casa.');
      expect(recipe.descriptionEs, 'Ragú cocido despacio y bechamel casera.');
      expect(recipe.descriptionEn, 'Slow-cooked ragù and homemade béchamel.');

      final none = Recipe.fromJson(recipeRow(descriptionIt: null, descriptionEs: ''));
      expect(none.descriptionIt, isNull);
      expect(none.descriptionEs, isNull);
      expect(none.descriptionEn, isNull);
      // Una fila de antes de la migración del menú (sin las columnas).
      final old = Recipe.fromJson(
        recipeRow()
          ..remove('description_it')
          ..remove('description_es')
          ..remove('description_en'),
      );
      expect(old.descriptionIt, isNull);
    });

    test('la foto: photo_id o null (sin foto)', () {
      const photoId = 'f0000000-0000-4000-8000-000000000001';
      expect(Recipe.fromJson(recipeRow(photoId: photoId)).photoId, photoId);
      expect(Recipe.fromJson(recipeRow()).photoId, isNull);
    });

    test('las cuatro secciones compuestas y las tres unidades se leen bien', () {
      final recipe = Recipe.fromJson(
        recipeRow(
          ingredients: const [
            {'position': 1, 'name': 'A', 'section': 'produce', 'quantity': 1, 'unit': 'pcs'},
            {'position': 2, 'name': 'B', 'section': 'dairy_eggs', 'quantity': 2, 'unit': 'ml'},
            {'position': 3, 'name': 'C', 'section': 'bakery', 'quantity': 3, 'unit': 'g'},
            {'position': 4, 'name': 'D', 'section': 'frozen', 'quantity': null, 'unit': null},
            {'position': 5, 'name': 'E', 'section': 'other', 'quantity': null, 'unit': null},
          ],
        ),
      );
      expect(recipe.ingredients.map((i) => i.section), [
        ShoppingSection.produce,
        ShoppingSection.dairyEggs,
        ShoppingSection.bakery,
        ShoppingSection.frozen,
        ShoppingSection.other,
      ]);
      expect(recipe.ingredients.first.amount, (quantity: 1, unit: IngredientUnit.pcs));
    });

    // Un valor que esta versión no conoce no se descarta en silencio: al
    // guardar se perdería (save_recipe reemplaza alérgenos e ingredientes).
    for (final (label, row) in [
      ('sin id', recipeRow(id: '')),
      ('nombre que no es texto', recipeRow(nameIt: 3)),
      ('descripción que no es texto', recipeRow(descriptionIt: 3)),
      ('foto que no es texto', recipeRow(photoId: 3)),
      ('foto que no es un uuid', recipeRow(photoId: '../otra-cocina')),
      ('alérgeno desconocido', recipeRow(allergens: const [{'allergen': 'kiwi'}])),
      ('dieta desconocida', recipeRow(diet: 'pescatarian')),
      ('sección desconocida', recipeRow(ingredients: const [
        {'position': 1, 'name': 'A', 'section': 'deli', 'quantity': null, 'unit': null},
      ])),
      ('unidad desconocida', recipeRow(ingredients: const [
        {'position': 1, 'name': 'A', 'section': 'other', 'quantity': 2, 'unit': 'tbsp'},
      ])),
      ('cantidad sin unidad', recipeRow(ingredients: const [
        {'position': 1, 'name': 'A', 'section': 'other', 'quantity': 2, 'unit': null},
      ])),
      ('unidad sin cantidad', recipeRow(ingredients: const [
        {'position': 1, 'name': 'A', 'section': 'other', 'quantity': null, 'unit': 'g'},
      ])),
      ('mes 13', recipeRow(seasonMonths: [13])),
      ('días que no son enteros', recipeRow(fridgeDays: '3')),
      ('sin la lista de ingredientes', recipeRow(ingredients: null)),
      ('dos filas de notas', recipeRow(notes: const [
        {'notes': 'A'},
        {'notes': 'B'},
      ])),
      ('notas que no son texto', recipeRow(notes: const [
        {'notes': 3},
      ])),
      ('notas que no son una fila', recipeRow(notes: const ['Senza aglio.'])),
    ]) {
      test('fila rota ($label): FormatException', () {
        expect(() => Recipe.fromJson(row), throwsFormatException);
      });
    }

    test('toString no muestra nombres ni notas', () {
      expect(risotto().toString(), 'Recipe($risottoId)');
      expect('${[risotto()]}', isNot(contains('burro')));
    });
  });

  group('recipeSavePayload', () {
    test('el plato entero, con las claves de save_recipe y q.b. sin cantidad ni unidad', () {
      expect(recipeSavePayload(lasagne()), {
        'id': lasagneId,
        'name_it': 'Lasagne alla bolognese',
        'name_es': 'Lasaña a la boloñesa',
        'name_en': 'Lasagne Bolognese',
        'description_it': 'Ragù cotto piano e besciamella fatta in casa.',
        'description_es': 'Ragú cocido despacio y bechamel casera.',
        'description_en': null,
        'diet': null,
        'season_months': null,
        'fridge_days': 3,
        'freezable': true,
        'freezer_days': 60,
        'notes': null,
        'allergens': ['gluten', 'eggs', 'milk', 'celery'],
        'ingredients': [
          {'name': 'Carne macinata di manzo', 'section': 'meat_fish', 'quantity': 400, 'unit': 'g'},
          {'name': 'Passata di pomodoro', 'section': 'pantry', 'quantity': 700, 'unit': 'ml'},
          {'name': 'Sale', 'section': 'pantry', 'quantity': null, 'unit': null},
        ],
      });
    });

    test('dieta, meses y notas', () {
      final payload = recipeSavePayload(risotto());
      expect(payload['diet'], 'vegetarian');
      expect(payload['season_months'], [9, 10, 11]);
      expect(payload['notes'], 'Si può fare senza burro e parmigiano.');
      expect(payload['allergens'], ['milk', 'celery', 'sulphites']);
      expect(payload['ingredients'], isEmpty);
    });

    // Las tres van siempre: null borra la que se vació en el editor
    // (save_recipe solo deja como está una clave que no viene).
    test('las tres descripciones van siempre, null si no hay', () {
      final payload = recipeSavePayload(minestrone());
      expect(payload.containsKey('description_it'), isTrue);
      expect(payload['description_it'], isNull);
      expect(payload['description_es'], isNull);
      expect(payload['description_en'], isNull);
      expect(recipeSavePayload(risotto())['description_it'], 'Porcini freschi e parmigiano.');
    });

    // Activar o desactivar es otra acción: guardar nunca reactiva un plato
    // (save_recipe no toca una clave que no viene).
    test('nunca manda active ni catalog_visible', () {
      final payload = recipeSavePayload(frittata());
      expect(payload.containsKey('active'), isFalse);
      expect(payload.containsKey('catalog_visible'), isFalse);
    });

    // La foto la pone set_recipe_photo, después de subir los archivos;
    // save_recipe no la toca (duplicar un plato no la copia).
    test('nunca manda la foto', () {
      final payload = recipeSavePayload(lasagne().copyWith(photoId: 'f0000000-0000-4000-8000-000000000001'));
      expect(payload.containsKey('photo_id'), isFalse);
      expect(payload.values, isNot(contains('f0000000-0000-4000-8000-000000000001')));
    });
  });

  // get_public_menu: activo, en el catálogo (la lista solo trae esos) y con
  // descripción en italiano.
  group('en la web', () {
    test('publicado si está activo y tiene la descripción en italiano', () {
      expect(lasagne().webStatus, RecipeWebStatus.published);
      expect(risotto().webStatus, RecipeWebStatus.published, reason: 'sin la española ni la inglesa también');
    });

    test('activo sin descripción en italiano: le falta para estar en la web', () {
      expect(minestrone().webStatus, RecipeWebStatus.missingDescription);
      expect(
        lasagne().copyWith(descriptionIt: null).webStatus,
        RecipeWebStatus.missingDescription,
        reason: 'la española sola no alcanza',
      );
    });

    test('desactivado no sale, tenga o no descripción', () {
      expect(frittata().webStatus, RecipeWebStatus.inactive);
      expect(minestrone().copyWith(active: false).webStatus, RecipeWebStatus.inactive);
    });
  });

  group('nombres', () {
    test('sin espacios de más ni caracteres de control', () {
      expect(normalizeRecipeText('  Lasagne   alla\tbolognese \n'), 'Lasagne alla bolognese');
      expect(normalizeRecipeText('Pollo\u0007al\u0085limone '), 'Pollo al limone');
      expect(normalizeRecipeText(' Sale '), 'Sale');
      expect(normalizeRecipeText('   '), '');
    });

    test('el largo cuenta caracteres como Postgres (un emoji es uno)', () {
      expect(textLength('🍝ab'), 3);
      expect(textLength('Città'), 5);
    });

    // El que usan la validación y el contador del editor: lo que va a
    // guardar la base, contado como char_length.
    test('recipeTextLength: sin los espacios de más, una bandera o un acento aparte cuentan dos', () {
      expect(recipeTextLength('  Pesto   alla\tgenovese \n'), 'Pesto alla genovese'.length);
      expect(recipeTextLength('   '), 0);
      expect(recipeTextLength('🇮🇹'), 2, reason: 'dos code points, aunque se vea uno');
      expect(recipeTextLength('Città'), 6, reason: 'la «à» en NFD es una a y el acento');
      expect(recipeTextLength('🍝'), 1);
    });
  });

  group('temporada', () {
    test('normalizeSeasonMonths: ordenados, sin repetir; ninguno o los 12 es todo el año', () {
      expect(normalizeSeasonMonths(null), isNull);
      expect(normalizeSeasonMonths(const []), isNull);
      expect(normalizeSeasonMonths([for (var m = 12; m >= 1; m--) m]), isNull);
      expect(normalizeSeasonMonths(const [11, 9, 10, 9]), [9, 10, 11]);
      expect(() => normalizeSeasonMonths(const [0]), throwsRangeError);
      expect(() => normalizeSeasonMonths(const [13]), throwsRangeError);
    });

    test('isInSeason', () {
      expect(isInSeason(null, 7), isTrue);
      expect(isInSeason(const [9, 10, 11], 10), isTrue);
      expect(isInSeason(const [9, 10, 11], 12), isFalse);
    });

    test('seasonRanges: tramos seguidos, con la vuelta de diciembre a enero', () {
      expect(seasonRanges(const [9, 10, 11]), [(first: 9, last: 11)]);
      expect(seasonRanges(const [1, 2, 3, 4, 10, 11, 12]), [(first: 10, last: 4)]);
      expect(seasonRanges(const [5, 6, 7, 8, 9]), [(first: 5, last: 9)]);
      expect(seasonRanges(const [1, 3, 5]), [
        (first: 1, last: 1),
        (first: 3, last: 3),
        (first: 5, last: 5),
      ]);
      expect(seasonRanges(const [1, 2, 6, 11, 12]), [
        (first: 6, last: 6),
        (first: 11, last: 2),
      ]);
      expect(seasonRanges(const [12]), [(first: 12, last: 12)]);
      expect(seasonRanges(const [1, 12]), [(first: 12, last: 1)]);
    });
  });

  group('dieta y alérgenos', () {
    test('un plato vegano no lleva productos animales', () {
      expect(
        dietConflicts(Diet.vegan, const [Allergen.milk, Allergen.celery, Allergen.eggs]),
        [Allergen.eggs, Allergen.milk],
      );
      expect(dietConflicts(Diet.vegan, const [Allergen.celery, Allergen.gluten]), isEmpty);
    });

    test('uno vegetariano no lleva pescado ni mariscos (leche y huevos sí)', () {
      expect(
        dietConflicts(Diet.vegetarian, const [
          Allergen.molluscs,
          Allergen.milk,
          Allergen.fish,
          Allergen.eggs,
          Allergen.crustaceans,
        ]),
        [Allergen.crustaceans, Allergen.fish, Allergen.molluscs],
      );
    });

    // Los conjuntos son literales aparte: el vegano no sale del vegetariano.
    test('los dos conjuntos completos, contra los 14 alérgenos', () {
      expect(dietConflicts(Diet.vegan, Allergen.values), [
        Allergen.crustaceans,
        Allergen.eggs,
        Allergen.fish,
        Allergen.milk,
        Allergen.molluscs,
      ]);
      expect(dietConflicts(Diet.vegetarian, Allergen.values), [
        Allergen.crustaceans,
        Allergen.fish,
        Allergen.molluscs,
      ]);
    });

    test('sin dieta no hay choque', () {
      expect(dietConflicts(null, Allergen.values), isEmpty);
    });
  });

  group('búsqueda', () {
    test('foldForSearch: minúsculas y sin acentos', () {
      expect(foldForSearch('Città Àlta Ñandú Çà'), 'citta alta nandu ca');
      expect(foldForSearch('Pâté FRITTO'), 'pate fritto');
    });

    test('busca en los nombres de los tres idiomas, sin mayúsculas ni acentos', () {
      expect(recipeMatchesQuery(lasagne(), 'lasagne'), isTrue);
      expect(recipeMatchesQuery(lasagne(), 'LASAÑA'), isTrue);
      expect(recipeMatchesQuery(lasagne(), 'lasana'), isTrue);
      expect(recipeMatchesQuery(lasagne(), 'bolognese'), isTrue);
      expect(recipeMatchesQuery(risotto(), 'hongos'), isTrue);
      expect(recipeMatchesQuery(risotto(), 'mushroom'), isTrue);
      expect(recipeMatchesQuery(risotto(), 'lasagne'), isFalse);
    });

    test('todas las palabras tienen que estar, en cualquier orden', () {
      expect(recipeMatchesQuery(risotto(), 'porcini risotto'), isTrue);
      expect(recipeMatchesQuery(risotto(), 'risotto lasagne'), isFalse);
      expect(recipeMatchesQuery(risotto(), '   '), isTrue);
    });
  });

  group('vista del catálogo', () {
    test('activos primero y por nombre en italiano; los desactivados al final', () {
      final view = recipeCatalogView(sampleRecipes());
      expect(view.active.map((r) => r.id), [lasagneId, minestroneId, risottoId]);
      expect(view.inactive.map((r) => r.id), [frittataId]);
      expect(view.total, 4);
      expect(view.isEmpty, isFalse);
    });

    test('la búsqueda filtra los dos grupos y total sigue contando todo', () {
      final view = recipeCatalogView(sampleRecipes(), query: 'zapallitos');
      expect(view.active, isEmpty);
      expect(view.inactive.map((r) => r.id), [frittataId]);
      expect(view.total, 4);

      final none = recipeCatalogView(sampleRecipes(), query: 'sushi');
      expect(none.isEmpty, isTrue);
      expect(none.total, 4);
    });

    test('catálogo vacío', () {
      final view = recipeCatalogView(const []);
      expect(view.isEmpty, isTrue);
      expect(view.total, 0);
    });

    test('hasRecipeNamed: el mismo nombre sin importar mayúsculas, acentos ni espacios', () {
      final recipes = sampleRecipes();
      expect(hasRecipeNamed(recipes, '  lasagne ALLA   bolognese'), isTrue);
      expect(hasRecipeNamed(recipes, 'Lasagne alla bolognese', exceptId: lasagneId), isFalse);
      expect(hasRecipeNamed(recipes, 'Lasagne vegetariane'), isFalse);
      expect(hasRecipeNamed(recipes, '  '), isFalse);
    });
  });
}

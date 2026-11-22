// Reglas del menú de una semana: los choques de un plato con las alergias y
// la dieta de la reserva, las porciones por defecto, la primera semana y los
// platos que eligió la clienta, la nota y los renglones escritos a mano como
// los guarda la base, la lectura de las filas y el argumento de
// save_session_menu.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/menu_fixtures.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  group('dishConflict', () {
    const none = (allergens: <Allergen>[], diets: <Diet>[]);

    test('sin restricciones, ningún plato choca', () {
      expect(dishConflict(lasagne(), none).isEmpty, isTrue);
    });

    test(
      'los alérgenos del plato que la reserva evita, en el orden del enum',
      () {
        final conflict = dishConflict(lasagne(), (
          allergens: [Allergen.milk, Allergen.gluten, Allergen.peanuts],
          diets: <Diet>[],
        ));
        expect(conflict.allergens, [Allergen.gluten, Allergen.milk]);
        expect(conflict.diets, isEmpty);
        expect(conflict.isNotEmpty, isTrue);
      },
    );

    test('una reserva vegetariana: choca un plato sin dieta marcada, no uno vegetariano ni uno vegano', () {
      const vegetarian = (allergens: <Allergen>[], diets: [Diet.vegetarian]);
      expect(dishConflict(lasagne(), vegetarian).diets, [Diet.vegetarian]);
      expect(dishConflict(risotto(), vegetarian).isEmpty, isTrue);
      expect(dishConflict(minestrone(), vegetarian).isEmpty, isTrue);
    });

    test('una reserva vegana: solo un plato vegano no choca', () {
      const vegan = (allergens: <Allergen>[], diets: [Diet.vegan]);
      expect(dishConflict(risotto(), vegan).diets, [Diet.vegan]);
      expect(dishConflict(lasagne(), vegan).diets, [Diet.vegan]);
      expect(dishConflict(minestrone(), vegan).isEmpty, isTrue);
    });

    test(
      'las restricciones de la reserva salen de la sesión (pedido y ficha)',
      () {
        final session = buildSession(
          clientAllergens: const [Allergen.celery],
          restrictions: const RequestRestrictions(
            allergens: [Allergen.milk],
            diets: [Diet.vegetarian],
          ),
        );
        final restrictions = menuRestrictionsOf(session);
        expect(restrictions.allergens, [Allergen.milk, Allergen.celery]);
        expect(restrictions.diets, [Diet.vegetarian]);
        expect(
          dishConflict(risotto(), restrictions),
          const DishConflict(allergens: [Allergen.milk, Allergen.celery]),
        );
      },
    );
  });

  group('defaultDishPortions', () {
    test('personas por comidas de cada día: 4 personas que cenan, 4', () {
      expect(defaultDishPortions(buildSession()), 4);
    });

    test('con almuerzo y cena, el doble', () {
      expect(
        defaultDishPortions(
          buildSession(meals: const [Meal.lunch, Meal.dinner]),
        ),
        8,
      );
    });

    test('sin pedido, las personas de la ficha y una comida', () {
      expect(defaultDishPortions(buildSession(requestId: null)), 4);
    });

    test('al menos 1 y como mucho 500', () {
      final nobody = buildSession(requestId: null)
          .copyWith(client: const SessionClient(displayName: 'X'));
      expect(defaultDishPortions(nobody), 1);
      final crowd = buildSession().copyWith(
        request: buildSession().request!.copyWith(
          adults: 300,
          kids: 0,
          meals: const [Meal.lunch, Meal.dinner],
        ),
      );
      expect(defaultDishPortions(crowd), maxDishPortions);
    });
  });

  group('isFirstWeekOfBooking', () {
    test('la primera semana viva de la reserva', () {
      final booking = buildBooking();
      expect(isFirstWeekOfBooking(booking[0], booking), isTrue);
      expect(isFirstWeekOfBooking(booking[1], booking), isFalse);
    });

    test('si la primera se canceló, la siguiente pasa a ser la primera', () {
      final booking = buildBooking(
        statuses: const {1: SessionStatus.cancelled},
      );
      expect(isFirstWeekOfBooking(booking[1], booking), isTrue);
      expect(isFirstWeekOfBooking(booking[0], booking), isFalse);
    });

    test('una sesión sin reserva es su propia primera semana', () {
      final alone = buildSession(requestId: null);
      expect(isFirstWeekOfBooking(alone, [alone]), isTrue);
    });
  });

  test('dishesFromWishes: los que siguen en el catálogo y activos, en orden, sin repetir', () {
    final dishes = dishesFromWishes(
      [risottoId, 'borrado', frittataId, lasagneId, risottoId],
      sampleRecipes(),
      portions: 6,
    );
    expect([for (final d in dishes) d.recipe.id], [risottoId, lasagneId]);
    expect(dishes.every((d) => d.portions == 6), isTrue);
  });

  test('dishesFromWishes: como mucho 30', () {
    final catalog = [for (var n = 1; n <= 40; n++) dishWith(n, const [])];
    final dishes = dishesFromWishes(
      [for (final r in catalog) r.id],
      catalog,
      portions: 1,
    );
    expect(dishes, hasLength(maxMenuDishes));
  });

  test('isMenuEditable: held, confirmed o una vieja en shopping_done', () {
    expect(
      {
        for (final status in SessionStatus.values)
          status: isMenuEditable(status),
      },
      {
        SessionStatus.held: true,
        SessionStatus.confirmed: true,
        SessionStatus.shoppingDone: true,
        SessionStatus.cooked: false,
        SessionStatus.paid: false,
        SessionStatus.cancelled: false,
      },
    );
  });

  group('la nota', () {
    test('los saltos de Windows y de un Mac viejo pasan a \\n, otro control a espacio, sin bordes', () {
      expect(
        normalizeMenuNote('  Tené listos\r\n4 táperes\rgrandes\t \n'),
        'Tené listos\n4 táperes\ngrandes',
      );
      expect(normalizeMenuNote('a\u0000b'), 'a b');
    });

    test('vacía o solo espacios, null', () {
      expect(normalizeMenuNote(''), isNull);
      expect(normalizeMenuNote(' \n\t '), isNull);
    });

    test(
      'el largo se cuenta como la base: por caracteres y ya normalizada',
      () {
        expect(menuNoteLength('  🍝🍝 \n'), 2);
        expect(menuNoteLength('a' * 1001), 1001);
      },
    );
  });

  group('un renglón escrito a mano', () {
    test('el nombre normalizado y la cantidad entera en la unidad elegida', () {
      expect(
        shoppingItemFrom(
          name: '  Panna   da cucina ',
          quantity: '250',
          unit: UnitChoice.ml,
          section: ShoppingSection.dairyEggs,
        ),
        item(
          'Panna da cucina',
          250,
          IngredientUnit.ml,
          section: ShoppingSection.dairyEggs,
        ),
      );
      expect(
        shoppingItemFrom(
          name: 'Sale',
          quantity: '12',
          unit: UnitChoice.toTaste,
          section: ShoppingSection.pantry,
        ),
        toTasteItem('Sale'),
      );
    });

    test(
      'sin nombre, con más de 80 caracteres o sin cantidad válida, no vale',
      () {
        expect(
          validateShoppingItem(
            name: ' ',
            quantity: '1',
            unit: UnitChoice.g,
          ).name,
          TextError.required,
        );
        expect(
          validateShoppingItem(
            name: 'x' * 81,
            quantity: '1',
            unit: UnitChoice.g,
          ).name,
          TextError.tooLong,
        );
        expect(
          validateShoppingItem(
            name: 'Riso',
            quantity: '',
            unit: UnitChoice.g,
          ).quantity,
          QuantityError.required,
        );
        expect(
          validateShoppingItem(
            name: 'Riso',
            quantity: '0',
            unit: UnitChoice.g,
          ).quantity,
          QuantityError.outOfRange,
        );
        expect(
          validateShoppingItem(
            name: 'Riso',
            quantity: '1000001',
            unit: UnitChoice.g,
          ).quantity,
          QuantityError.outOfRange,
        );
        expect(
          validateShoppingItem(
            name: 'Riso',
            quantity: '1000000',
            unit: UnitChoice.g,
          ),
          (name: null, quantity: null),
        );
        // q.b. no lleva cantidad.
        expect(
          validateShoppingItem(
            name: 'Sale',
            quantity: '',
            unit: UnitChoice.toTaste,
          ),
          (name: null, quantity: null),
        );
        expect(
          shoppingItemFrom(
            name: '',
            quantity: '1',
            unit: UnitChoice.g,
            section: ShoppingSection.other,
          ),
          isNull,
        );
      },
    );
  });

  group('SavedWeekMenu.fromSessionRow', () {
    Map<String, dynamic> row({Object? menu, Object? dishes, Object? items}) => {
      'id': sessionId(1),
      'menu': menu,
      'dishes': dishes ?? const <Object>[],
      'items': items ?? const <Object>[],
    };

    test('sin la fila de session_menus: sin menú', () {
      final saved = SavedWeekMenu.fromSessionRow(row(menu: const <Object>[]));
      expect(saved.exists, isFalse);
      expect(saved.version, isNull);
      expect(SavedWeekMenu.fromSessionRow(row()).exists, isFalse);
    });

    test('la versión, la nota, los platos y la lista, por posición (la fila sola o en una lista)', () {
      for (final menu in [
        {
          'version': 3,
          'note': 'Tené listos 4 táperes',
          'allergens_confirmed': true,
        },
        [
          {
            'version': 3,
            'note': 'Tené listos 4 táperes',
            'allergens_confirmed': true,
          },
        ],
      ]) {
        final saved = SavedWeekMenu.fromSessionRow(
          row(
            menu: menu,
            dishes: [
              {
                'position': 2,
                'portions': 6,
                'recipe': menuRecipeRow(id: risottoId),
              },
              {'position': 1, 'portions': 4, 'recipe': menuRecipeRow()},
            ],
            items: const [
              {
                'position': 2,
                'name': 'Sale',
                'section': 'pantry',
                'quantity': null,
                'unit': null,
              },
              {
                'position': 1,
                'name': 'Carne',
                'section': 'meat_fish',
                'quantity': 400,
                'unit': 'g',
              },
            ],
          ),
        );
        expect(saved.version, 3);
        expect(saved.note, 'Tené listos 4 táperes');
        expect(saved.allergensConfirmed, isTrue);
        expect(
          [for (final d in saved.dishes) (d.recipe.id, d.portions)],
          [(lasagneId, 4), (risottoId, 6)],
        );
        final recipe = saved.dishes.first.recipe;
        expect(recipe.nameEs, 'Lasaña a la boloñesa');
        expect(recipe.allergens, lasagne().allergens);
        expect(recipe.ingredients, lasagne().ingredients);
        expect(recipe.notes, isNull);
        expect(saved.items, [
          item(
            'Carne',
            400,
            IngredientUnit.g,
            section: ShoppingSection.meatFish,
          ),
          toTasteItem('Sale'),
        ]);
      }
    });

    test('una fila rota o con un valor que no conoce da FormatException', () {
      expect(
        () => SavedWeekMenu.fromSessionRow({
          'menu': null,
          'dishes': null,
          'items': const <Object>[],
        }),
        throwsFormatException,
      );
      expect(
        () => SavedWeekMenu.fromSessionRow(
          row(
            menu: {'version': '1', 'note': null, 'allergens_confirmed': false},
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => SavedWeekMenu.fromSessionRow(
          row(
            items: const [
              {
                'position': 1,
                'name': 'X',
                'section': 'garden',
                'quantity': null,
                'unit': null,
              },
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => SavedWeekMenu.fromSessionRow(
          row(
            items: const [
              {
                'position': 1,
                'name': 'X',
                'section': 'other',
                'quantity': 3,
                'unit': null,
              },
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => SavedWeekMenu.fromSessionRow(
          row(
            dishes: const [
              {'position': 1, 'portions': 4, 'recipe': null},
            ],
          ),
        ),
        throwsFormatException,
      );
    });

    test('no imprime la nota', () {
      final saved = savedLasagneMenu(note: 'Tené listos 4 táperes');
      expect(saved.toString(), isNot(contains('táperes')));
    });
  });

  test('weekMenuSummaryFromRow cuenta platos y renglones', () {
    expect(
      weekMenuSummaryFromRow({
        'id': sessionId(1),
        'menu': const [
          {'version': 2},
        ],
        'dishes': const [
          {'recipe_id': lasagneId},
          {'recipe_id': risottoId},
        ],
        'items': const [
          {'position': 1},
        ],
      }),
      const WeekMenuSummary(saved: true, dishes: 2, items: 1, version: 2),
    );
    expect(
      weekMenuSummaryFromRow({
        'id': sessionId(1),
        'menu': null,
        'dishes': const <Object>[],
        'items': const <Object>[],
      }),
      const WeekMenuSummary(),
    );
    // La fila de session_menus sin una versión que sea un número: rota.
    expect(
      () => weekMenuSummaryFromRow({
        'id': sessionId(1),
        'menu': const {'version': '2'},
        'dishes': const <Object>[],
        'items': const <Object>[],
      }),
      throwsFormatException,
    );
  });

  group('lo que se guarda', () {
    final save = WeekMenuSave(
      sessionId: sessionId(1),
      version: 2,
      note: 'Tené listos 4 táperes',
      allergensConfirmed: true,
      dishes: [WeekMenuDish(recipe: lasagne(), portions: 6)],
      items: [
        item('Carne', 600, IngredientUnit.g, section: ShoppingSection.meatFish),
        toTasteItem('Sale'),
      ],
    );

    test('weekMenuSavePayload: todas las claves, los platos y los renglones en orden', () {
      expect(weekMenuSavePayload(save), {
        'session_id': sessionId(1),
        'version': 2,
        'note': 'Tené listos 4 táperes',
        'allergens_confirmed': true,
        'dishes': [
          {'recipe_id': lasagneId, 'portions': 6},
        ],
        'items': [
          {
            'name': 'Carne',
            'section': 'meat_fish',
            'quantity': 600,
            'unit': 'g',
          },
          {'name': 'Sale', 'section': 'pantry', 'quantity': null, 'unit': null},
        ],
      });
    });

    test('un menú nuevo manda version null y la nota vacía, null', () {
      final payload = weekMenuSavePayload(
        WeekMenuSave(
          sessionId: sessionId(1),
          allergensConfirmed: false,
          dishes: const [],
          items: const [],
        ),
      );
      expect(payload.containsKey('version'), isTrue);
      expect(payload['version'], isNull);
      expect(payload.containsKey('note'), isTrue);
      expect(payload['note'], isNull);
    });

    test('matches: lo guardado es lo que se mandó (platos, porciones, lista, nota y confirmación)', () {
      final saved = SavedWeekMenu(
        version: 3,
        note: save.note,
        allergensConfirmed: true,
        dishes: save.dishes,
        items: save.items,
      );
      expect(saved.matches(save), isTrue);
      expect(saved.copyWith(note: null).matches(save), isFalse);
      expect(saved.copyWith(allergensConfirmed: false).matches(save), isFalse);
      expect(
        saved
            .copyWith(dishes: [WeekMenuDish(recipe: lasagne(), portions: 4)])
            .matches(save),
        isFalse,
      );
      expect(
        saved.copyWith(items: save.items.reversed.toList()).matches(save),
        isFalse,
      );
    });

    test('no imprime la nota', () {
      expect(save.toString(), isNot(contains('táperes')));
    });
  });

  group('el selector de platos', () {
    test('recipeNameIn: el nombre en el idioma de la app, con el italiano si falta', () {
      expect(recipeNameIn(lasagne(), 'es'), 'Lasaña a la boloñesa');
      expect(recipeNameIn(lasagne(), 'en'), 'Lasagne Bolognese');
      expect(recipeNameIn(lasagne(), 'it'), 'Lasagne alla bolognese');
      expect(recipeNameIn(minestrone(), 'en'), 'Minestrone di verdure');
      expect(recipeNameIn(pastel(), 'es'), 'Pastel de papa');
    });

    test('menuPickerCandidates: los activos que no están en el menú, por su nombre en el idioma de la app', () {
      final catalog = [...sampleRecipes(), milanesa()];
      expect(
        [
          for (final r in menuPickerCandidates(
            catalog,
            chosen: {risottoId},
            languageCode: 'es',
          ))
            recipeNameIn(r, 'es'),
        ],
        [
          'Lasaña a la boloñesa',
          'Milanesa a la napolitana',
          'Minestrone de verduras',
        ],
      );
    });

    test(
      'menuPickerCandidates: la búsqueda mira los tres nombres, sin acentos',
      () {
        List<String> ids(String query) => [
          for (final r in menuPickerCandidates(
            sampleRecipes(),
            chosen: const {},
            languageCode: 'es',
            query: query,
          ))
            r.id,
        ];
        expect(ids('lasana'), [lasagneId]);
        expect(ids('porcini'), [risottoId]);
        expect(ids('mushroom'), [risottoId]);
        // La tortilla está desactivada.
        expect(ids('tortilla'), isEmpty);
      },
    );
  });
}

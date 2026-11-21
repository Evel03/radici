// La lista de compras que sale de los platos de una semana: las cantidades
// llevadas a las porciones (para arriba, y en g o ml desde 100 a la decena),
// los iguales juntos, los «q.b.» una vez, por sección y en el orden en que
// aparecen, con los topes de la base.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/week_menu/domain/shopping_list.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/menu_fixtures.dart';
import '../../../support/recipe_fixtures.dart';

void main() {
  group('scaledQuantity', () {
    test(
      'para arriba, y en g o ml de 100 para arriba a la decena siguiente',
      () {
        expect(scaledQuantity(400, IngredientUnit.g, 4), 400);
        expect(scaledQuantity(400, IngredientUnit.g, 6), 600);
        // 103: más de 100, a la decena siguiente.
        expect(scaledQuantity(103, IngredientUnit.g, 4), 110);
        // 100 justo no se redondea.
        expect(scaledQuantity(100, IngredientUnit.ml, 4), 100);
        expect(scaledQuantity(101, IngredientUnit.ml, 4), 110);
        // 250 × 5 / 4 = 312,5 → 313 → 320.
        expect(scaledQuantity(250, IngredientUnit.ml, 5), 320);
        // 50 × 3 / 4 = 37,5 → 38: debajo de 100 queda.
        expect(scaledQuantity(50, IngredientUnit.g, 3), 38);
        // 1 g para 1 porción: 0,25 → 1.
        expect(scaledQuantity(1, IngredientUnit.g, 1), 1);
      },
    );

    test('las piezas quedan como dan, aunque pasen de 100', () {
      // 7 × 3 / 4 = 5,25 → 6.
      expect(scaledQuantity(7, IngredientUnit.pcs, 3), 6);
      expect(scaledQuantity(101, IngredientUnit.pcs, 4), 101);
    });
  });

  group('buildShoppingList', () {
    test('sin platos, vacía', () {
      final list = buildShoppingList(const []);
      expect(list.items, isEmpty);
      expect(list.truncated, isFalse);
    });

    test('la lasaña para 4: lo de la receta, con la sal q.b.', () {
      final list = buildShoppingList([
        WeekMenuDish(recipe: lasagne(), portions: 4),
      ]);
      expect(list.items, lasagneList(4));
      expect(list.truncated, isFalse);
    });

    test('junta los iguales (mismo nombre sin mayúsculas ni espacios, misma unidad) sumando, con el nombre y la sección de la primera vez', () {
      final list = buildShoppingList([
        WeekMenuDish(
          recipe: dishWith(1, [
            ingredient(
              'Cipolla ',
              2,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
            ingredient(
              'Farina',
              200,
              IngredientUnit.g,
              section: ShoppingSection.pantry,
            ),
          ]),
          portions: 4,
        ),
        WeekMenuDish(
          recipe: dishWith(2, [
            ingredient(
              'cipolla',
              1,
              IngredientUnit.pcs,
              section: ShoppingSection.other,
            ),
            ingredient(
              'FARINA',
              50,
              IngredientUnit.g,
              section: ShoppingSection.bakery,
            ),
          ]),
          portions: 8,
        ),
      ]);
      expect(list.items, [
        // 2 + 1 × 8 / 4 = 4 piezas, con la sección de la primera vez.
        item(
          'Cipolla',
          4,
          IngredientUnit.pcs,
          section: ShoppingSection.produce,
        ),
        // 200 + 50 × 8 / 4 = 300 g.
        item('Farina', 300, IngredientUnit.g, section: ShoppingSection.pantry),
      ]);
    });

    test('redondea cada plato y después suma', () {
      final list = buildShoppingList([
        WeekMenuDish(
          recipe: dishWith(1, [ingredient('Latte', 105, IngredientUnit.ml)]),
          portions: 4,
        ),
        WeekMenuDish(
          recipe: dishWith(2, [ingredient('Latte', 95, IngredientUnit.ml)]),
          portions: 4,
        ),
      ]);
      // 110 (redondeado) + 95.
      expect(list.items, [item('Latte', 205, IngredientUnit.ml)]);
    });

    test('el mismo nombre en otra unidad va en otro renglón', () {
      final list = buildShoppingList([
        WeekMenuDish(
          recipe: dishWith(1, [
            ingredient('Uova', 2, IngredientUnit.pcs),
            ingredient('Uova', 120, IngredientUnit.g),
          ]),
          portions: 4,
        ),
      ]);
      expect(list.items, [
        item('Uova', 2, IngredientUnit.pcs),
        item('Uova', 120, IngredientUnit.g),
      ]);
    });

    test('un q.b. va una sola vez, y ninguna si el mismo ingrediente va con cantidad', () {
      final list = buildShoppingList([
        WeekMenuDish(
          recipe: dishWith(1, [
            toTaste('Sale'),
            toTaste('Pepe'),
            toTaste('olio'),
          ]),
          portions: 4,
        ),
        WeekMenuDish(
          recipe: dishWith(2, [
            toTaste('sale'),
            ingredient(
              'Olio',
              30,
              IngredientUnit.ml,
              section: ShoppingSection.pantry,
            ),
          ]),
          portions: 4,
        ),
      ]);
      expect(list.items, [
        toTasteItem('Sale'),
        toTasteItem('Pepe'),
        item('Olio', 30, IngredientUnit.ml, section: ShoppingSection.pantry),
      ]);
    });

    test('por sección en el orden del súper y, dentro de cada una, en el orden en que aparecen', () {
      final list = buildShoppingList([
        WeekMenuDish(
          recipe: dishWith(1, [
            ingredient(
              'Surgelati misti',
              1,
              IngredientUnit.pcs,
              section: ShoppingSection.frozen,
            ),
            ingredient(
              'Pane',
              1,
              IngredientUnit.pcs,
              section: ShoppingSection.bakery,
            ),
            ingredient(
              'Zucchine',
              2,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
          ]),
          portions: 4,
        ),
        WeekMenuDish(
          recipe: dishWith(2, [
            ingredient(
              'Carote',
              3,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
            ingredient(
              'Pollo',
              500,
              IngredientUnit.g,
              section: ShoppingSection.meatFish,
            ),
            ingredient('Varie', 1, IngredientUnit.pcs),
            ingredient(
              'Latte',
              200,
              IngredientUnit.ml,
              section: ShoppingSection.dairyEggs,
            ),
            ingredient(
              'Riso',
              300,
              IngredientUnit.g,
              section: ShoppingSection.pantry,
            ),
          ]),
          portions: 4,
        ),
      ]);
      expect(
        [for (final i in list.items) i.name],
        [
          'Zucchine',
          'Carote',
          'Pollo',
          'Latte',
          'Pane',
          'Riso',
          'Surgelati misti',
          'Varie',
        ],
      );
    });

    test('ninguna cantidad pasa de 1.000.000', () {
      final list = buildShoppingList([
        for (var n = 1; n <= 3; n++)
          WeekMenuDish(
            recipe: dishWith(n, [
              ingredient('Acqua', maxIngredientQuantity, IngredientUnit.ml),
            ]),
            portions: maxDishPortions,
          ),
      ]);
      expect(list.items, [
        item('Acqua', maxShoppingQuantity, IngredientUnit.ml),
      ]);
    });

    test(
      'como mucho 150 renglones: con más, quedan los primeros y lo dice',
      () {
        final dishes = [
          for (var n = 1; n <= 4; n++)
            WeekMenuDish(
              recipe: dishWith(n, [
                for (var i = 1; i <= 40; i++)
                  ingredient('Cosa $n-$i', i, IngredientUnit.pcs),
              ]),
              portions: 4,
            ),
        ];
        final list = buildShoppingList(dishes);
        expect(list.items, hasLength(maxShoppingItems));
        expect(list.truncated, isTrue);
        expect(list.items.first.name, 'Cosa 1-1');
        expect(list.items.last.name, 'Cosa 4-30');
      },
    );
  });

  test('sortedBySection ordena por sección sin cambiar el orden dentro de cada una', () {
    final items = [
      item('B', 1, IngredientUnit.pcs, section: ShoppingSection.pantry),
      item('A', 1, IngredientUnit.pcs, section: ShoppingSection.produce),
      item('C', 1, IngredientUnit.pcs, section: ShoppingSection.pantry),
      item('D', 1, IngredientUnit.pcs, section: ShoppingSection.produce),
    ];
    expect(
      [for (final i in sortedBySection(items, (i) => i.section)) i.name],
      ['A', 'D', 'B', 'C'],
    );
  });
}

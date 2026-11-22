// La lista de compras que sale de los platos de una semana: las cantidades
// llevadas a las porciones (para arriba, y en g o ml desde 100 a la decena),
// los del mismo producto juntos (Cebolla y Cebollas sí; ajo y ají nunca), los
// «q.b.» una vez, por sección y en el orden en que aparecen, con los topes de
// la base.
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

  group('shoppingProductKey', () {
    test('en minúsculas, sin acentos, con un espacio entre palabras y sin la puntuación de alrededor', () {
      expect(shoppingProductKey('  Pimiento   ROJO '), 'pimiento rojo');
      expect(shoppingProductKey('Limón'), 'limon');
      // El acento aparte, como lo escribe un teclado que no lo compone.
      expect(shoppingProductKey('Limo\u0301n'), 'limon');
      expect(shoppingProductKey('Crème fraîche'), 'creme fraiche');
      expect(shoppingProductKey('Würstel'), 'wurstel');
      expect(shoppingProductKey('Curaçao'), 'curacao');
      for (final name in [
        'Cebolla,',
        '(cebolla)',
        '«Cebolla»',
        'cebolla.',
        '¡Cebolla!',
      ]) {
        expect(shoppingProductKey(name), 'cebolla', reason: name);
      }
      expect(shoppingProductKey('Sal (gruesa)'), 'sal gruesa');
      expect(shoppingProductKey('Cebolla - morada'), 'cebolla morada');
      // La de adentro de una palabra queda.
      expect(shoppingProductKey("Olio d'oliva"), "olio d'oliva");
      // Un nombre que es solo puntuación queda como está: dos así no se
      // juntan.
      expect(shoppingProductKey('-'), '-');
      expect(shoppingProductKey('¿?'), '¿?');
    });

    test('la ñ no es una n', () {
      expect(shoppingProductKey('Piña'), 'piña');
      expect(shoppingProductKey('PIÑAS'), 'piña');
      // La tilde aparte.
      expect(shoppingProductKey('Pin\u0303a'), 'piña');
      expect(shoppingProductKey('Jalapeños'), 'jalapeño');
      expect(shoppingProductKey('pina'), 'pina');
    });

    test('cada palabra en singular', () {
      const singular = {
        'cebollas': 'cebolla',
        'Tomates': 'tomate',
        'papas': 'papa',
        'Zanahorias': 'zanahoria',
        'pimientos rojos': 'pimiento rojo',
        // «-es» entero después de l, n, r, d, z, j o y.
        'limones': 'limon',
        'Flores': 'flor',
        'coles': 'col',
        'panes': 'pan',
        // El inglés sale con la misma regla.
        'onions': 'onion',
        // «-ces» a «-z», «-oes» a «-o»; «-ices» solo pierde la «s».
        'peces': 'pez',
        'nueces': 'nuez',
        'arroces': 'arroz',
        'tomatoes': 'tomato',
        'Potatoes': 'potato',
        'spices': 'spice',
        // «-ss» y las palabras de hasta 3 letras quedan.
        'Watercress': 'watercress',
        'carne de res': 'carne de res',
      };
      singular.forEach(
        (name, key) => expect(shoppingProductKey(name), key, reason: name),
      );
    });

    test('el singular y el plural son el mismo producto, pero dos productos distintos nunca', () {
      const same = [
        ('ajo', 'Ajos'),
        ('ají', 'ajís'),
        ('pimiento', 'pimientos'),
        ('pimiento rojo', 'Pimientos rojos'),
        ('papa', 'papas'),
        ('papaya', 'papayas'),
        ('pera', 'peras'),
        ('limón', 'limones'),
        ('lima', 'limas'),
        ('col', 'coles'),
        ('coliflor', 'coliflores'),
        ('pez', 'peces'),
        ('nuez', 'nueces'),
        ('tomato', 'tomatoes'),
        ('spice', 'spices'),
      ];
      for (final (a, b) in same) {
        expect(shoppingProductKey(a), shoppingProductKey(b), reason: '$a = $b');
      }
      const distinct = [
        ('ajo', 'ají'),
        ('ajos', 'ajíes'),
        ('pimiento', 'pimiento rojo'),
        ('pimientos', 'pimientos rojos'),
        ('papa', 'papaya'),
        ('papas', 'papayas'),
        ('pera', 'perejil'),
        ('peras', 'perejil'),
        ('limón', 'lima'),
        ('limones', 'limas'),
        ('col', 'coliflor'),
        ('coles', 'coliflores'),
        ('piña', 'pina'),
        ('pez', 'pera'),
        ('nuez', 'nuez moscada'),
        ('tomato', 'tomate'),
        ('arroces', 'arroz integral'),
      ];
      for (final (a, b) in distinct) {
        expect(
          shoppingProductKey(a),
          isNot(shoppingProductKey(b)),
          reason: '$a ≠ $b',
        );
      }
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

    test('junta los iguales (mismo producto, misma unidad) sumando, con el nombre y la sección de la primera vez', () {
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

    test('junta el mismo producto escrito distinto (Cebolla y Cebollas) sumando, con el nombre y la sección de la primera vez', () {
      final list = buildShoppingList([
        WeekMenuDish(
          recipe: dishWith(1, [
            ingredient(
              'Cebolla',
              3,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
            ingredient(
              'Limón',
              1,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
          ]),
          portions: 4,
        ),
        WeekMenuDish(
          recipe: dishWith(2, [
            ingredient('Cebollas', 1, IngredientUnit.pcs),
            ingredient(
              'limones',
              2,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
            ingredient(
              'Pimientos rojos',
              2,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
            ingredient(
              'pimiento rojo',
              1,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
          ]),
          portions: 4,
        ),
      ]);
      expect(list.items, [
        item(
          'Cebolla',
          4,
          IngredientUnit.pcs,
          section: ShoppingSection.produce,
        ),
        item('Limón', 3, IngredientUnit.pcs, section: ShoppingSection.produce),
        item(
          'Pimientos rojos',
          3,
          IngredientUnit.pcs,
          section: ShoppingSection.produce,
        ),
      ]);
    });

    test('nunca junta productos distintos', () {
      final list = buildShoppingList([
        WeekMenuDish(
          recipe: dishWith(1, [
            for (final name in [
              'Ajo',
              'Ají',
              'Pimiento',
              'Pimiento rojo',
              'Papa',
              'Papaya',
              'Pera',
              'Perejil',
              'Limón',
              'Lima',
              'Col',
              'Coliflor',
            ])
              ingredient(name, 1, IngredientUnit.pcs),
          ]),
          portions: 4,
        ),
        WeekMenuDish(
          recipe: dishWith(2, [
            for (final name in [
              'Ajos',
              'Pimientos',
              'Papas',
              'Peras',
              'Limones',
              'Coles',
            ])
              ingredient(name, 1, IngredientUnit.pcs),
          ]),
          portions: 4,
        ),
      ]);
      expect(list.items, [
        item('Ajo', 2, IngredientUnit.pcs),
        item('Ají', 1, IngredientUnit.pcs),
        item('Pimiento', 2, IngredientUnit.pcs),
        item('Pimiento rojo', 1, IngredientUnit.pcs),
        item('Papa', 2, IngredientUnit.pcs),
        item('Papaya', 1, IngredientUnit.pcs),
        item('Pera', 2, IngredientUnit.pcs),
        item('Perejil', 1, IngredientUnit.pcs),
        item('Limón', 2, IngredientUnit.pcs),
        item('Lima', 1, IngredientUnit.pcs),
        item('Col', 2, IngredientUnit.pcs),
        item('Coliflor', 1, IngredientUnit.pcs),
      ]);
    });

    test('el mismo producto en otra unidad va en otro renglón, justo después, con el nombre y la sección de la primera vez', () {
      final list = buildShoppingList([
        WeekMenuDish(
          recipe: dishWith(1, [
            ingredient(
              'Cebolla',
              3,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
            ingredient(
              'Zanahoria',
              2,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
          ]),
          portions: 4,
        ),
        WeekMenuDish(
          recipe: dishWith(2, [
            ingredient('cebollas', 200, IngredientUnit.g),
            ingredient(
              'Cebolla',
              1,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
          ]),
          portions: 4,
        ),
      ]);
      // Un renglón tiene una sola cantidad: 4 piezas y 200 g son dos, seguidos
      // aunque la zanahoria apareció antes que los gramos.
      expect(list.items, [
        item(
          'Cebolla',
          4,
          IngredientUnit.pcs,
          section: ShoppingSection.produce,
        ),
        item(
          'Cebolla',
          200,
          IngredientUnit.g,
          section: ShoppingSection.produce,
        ),
        item(
          'Zanahoria',
          2,
          IngredientUnit.pcs,
          section: ShoppingSection.produce,
        ),
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

    test('el q.b. también va una vez por producto, y ninguna si el producto va con cantidad', () {
      final list = buildShoppingList([
        WeekMenuDish(
          recipe: dishWith(1, [
            toTaste('Sal'),
            toTaste('Hoja de laurel'),
            toTaste('Limones'),
          ]),
          portions: 4,
        ),
        WeekMenuDish(
          recipe: dishWith(2, [
            toTaste('sal.'),
            toTaste('Hojas de laurel'),
            ingredient(
              'Limón',
              2,
              IngredientUnit.pcs,
              section: ShoppingSection.produce,
            ),
          ]),
          portions: 4,
        ),
      ]);
      expect(list.items, [
        // Con el nombre y la sección de la primera vez con cantidad.
        item('Limón', 2, IngredientUnit.pcs, section: ShoppingSection.produce),
        toTasteItem('Sal'),
        toTasteItem('Hoja de laurel'),
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

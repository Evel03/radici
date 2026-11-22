// La lista de compras que sale de los platos de una semana (SPEC 5.8): los
// ingredientes de cada plato (escritos para 4 porciones) llevados a sus
// porciones, juntando los iguales y agrupados por sección del súper. Es la que
// propone la app; Evelyn la edita y se guarda tal como queda. Dart puro.
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

/// La lista propuesta. [truncated]: salían más de [maxShoppingItems]
/// renglones y quedaron los primeros.
typedef ShoppingList = ({List<ShoppingItem> items, bool truncated});

/// Desde cuántos gramos o mililitros la cantidad se redondea a la decena
/// (para arriba): 103 g de harina se piden como 110 g.
const int roundToTensAbove = 100;

/// [quantity] (para [recipeBasePortions] porciones) llevada a [portions], en
/// enteros: para arriba, y en g o ml, de [roundToTensAbove] para arriba, a la
/// decena siguiente. Las piezas quedan como dan.
int scaledQuantity(int quantity, IngredientUnit unit, int portions) {
  final scaled =
      (quantity * portions + recipeBasePortions - 1) ~/ recipeBasePortions;
  if (unit == IngredientUnit.pcs || scaled <= roundToTensAbove) return scaled;
  return (scaled + 9) ~/ 10 * 10;
}

/// La lista de compras de [dishes]:
///
/// - cada ingrediente de cada plato, con su cantidad llevada a las porciones
///   del plato ([scaledQuantity]);
/// - los iguales (mismo nombre, sin importar mayúsculas ni espacios, y misma
///   unidad) en un solo renglón, sumados (hasta [maxShoppingQuantity]), con el
///   nombre y la sección de la primera vez que aparecen;
/// - un «q.b.» una sola vez, y ninguna si el mismo ingrediente ya va con
///   cantidad;
/// - por sección, en el orden del súper ([ShoppingSection]), y dentro de cada
///   una en el orden en que aparecen;
/// - como mucho [maxShoppingItems] renglones.
ShoppingList buildShoppingList(Iterable<WeekMenuDish> dishes) {
  final entries = <(String, IngredientUnit?), _Entry>{};
  final withQuantity = <String>{};
  var order = 0;
  for (final dish in dishes) {
    for (final ingredient in dish.recipe.ingredients) {
      final name = normalizeRecipeText(ingredient.name);
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      final amount = ingredient.amount;
      final quantity = amount == null
          ? null
          : scaledQuantity(amount.quantity, amount.unit, dish.portions);
      if (amount != null) withQuantity.add(key);
      final entry = entries[(key, amount?.unit)];
      if (entry == null) {
        entries[(key, amount?.unit)] = _Entry(
          name: name,
          section: ingredient.section,
          unit: amount?.unit,
          quantity: quantity,
          order: order++,
        );
      } else if (quantity != null) {
        entry.quantity = (entry.quantity! + quantity).clamp(
          1,
          maxShoppingQuantity,
        );
      }
    }
  }
  final kept = [
    for (final entry in entries.values)
      if (entry.unit != null ||
          !withQuantity.contains(entry.name.toLowerCase()))
        entry,
  ];
  kept.sort((a, b) {
    final bySection = a.section.index.compareTo(b.section.index);
    return bySection != 0 ? bySection : a.order.compareTo(b.order);
  });
  final items = [
    for (final entry in kept)
      ShoppingItem(
        name: entry.name,
        section: entry.section,
        amount: switch ((entry.quantity, entry.unit)) {
          (final int quantity, final IngredientUnit unit) => (
            quantity: quantity.clamp(1, maxShoppingQuantity),
            unit: unit,
          ),
          _ => null,
        },
      ),
  ];
  return items.length > maxShoppingItems
      ? (items: items.sublist(0, maxShoppingItems), truncated: true)
      : (items: items, truncated: false);
}

/// [items] por sección, en el orden del súper, sin cambiar el orden dentro de
/// cada una: así se muestran y así se guardan.
List<T> sortedBySection<T>(
  Iterable<T> items,
  ShoppingSection Function(T item) sectionOf,
) {
  final indexed = items.indexed.toList()
    ..sort((a, b) {
      final bySection = sectionOf(a.$2).index.compareTo(sectionOf(b.$2).index);
      return bySection != 0 ? bySection : a.$1.compareTo(b.$1);
    });
  return [for (final (_, item) in indexed) item];
}

/// Lo que se va juntando de un renglón.
final class _Entry {
  _Entry({
    required this.name,
    required this.section,
    required this.unit,
    required this.quantity,
    required this.order,
  });

  final String name;
  final ShoppingSection section;
  final IngredientUnit? unit;
  int? quantity;
  final int order;
}

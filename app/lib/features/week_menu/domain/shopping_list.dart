// La lista de compras que sale de los platos de una semana (SPEC 5.8): los
// ingredientes de cada plato (escritos para 4 porciones) llevados a sus
// porciones, juntando los del mismo producto (shoppingProductKey) y agrupados
// por sección del súper. Es la que propone la app; Evelyn la edita y se guarda
// tal como queda. Dart puro.
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

/// Puntuación al principio o al final de una palabra.
final RegExp _edgePunctuation = RegExp(r'^\p{P}+|\p{P}+$', unicode: true);

/// Una «s» final después de una letra que no es otra «s».
final RegExp _finalS = RegExp(r'[a-rt-zñ]s$');

/// Las letras después de las que el plural del español agrega «-es»
/// (limón → limones, flor → flores).
const Set<String> _esPluralAfter = {'l', 'n', 'r', 'd', 'z', 'j', 'y'};

/// El producto de un ingrediente, para juntar sus renglones en la lista: el
/// nombre en minúsculas, sin acentos (la ñ queda: es otra letra), sin la
/// puntuación de alrededor de cada palabra, con un espacio entre palabras y
/// cada una en singular ([_singular]). «Cebollas» y «cebolla» son el mismo
/// producto; «ajo» y «ají», «papa» y «papaya» o «col» y «coliflor», no. Un
/// nombre que es solo puntuación queda como está.
String shoppingProductKey(String name) {
  final folded = _withoutAccents(normalizeRecipeText(name).toLowerCase());
  final words = [
    for (final word in folded.split(' '))
      if (word.replaceAll(_edgePunctuation, '') case final bare
          when bare.isNotEmpty)
        _singular(bare),
  ];
  return words.isEmpty ? folded : words.join(' ');
}

/// [text], en minúsculas, sin acentos ([withoutAccent]) salvo la ñ, también
/// la escrita como una n con la tilde aparte.
String _withoutAccents(String text) {
  final buffer = StringBuffer();
  for (final rune in text.replaceAll('n\u0303', 'ñ').runes) {
    // Acentos sueltos (combinantes), por si el teclado no los compuso.
    if (rune >= 0x0300 && rune <= 0x036f) continue;
    final char = String.fromCharCode(rune);
    buffer.write(char == 'ñ' ? char : withoutAccent(char));
  }
  return buffer.toString();
}

/// [word] en singular, con reglas del español que, ante la duda, no juntan:
///
/// - después de l, n, r, d, z, j o y se va «-es» entero (limones → limon,
///   flores → flor);
/// - «-ces» pasa a «-z» (peces → pez, nueces → nuez, arroces → arroz), salvo
///   en «-ices» (spices sigue siendo spice) y «-oes» a «-o» (tomatoes →
///   tomato, potatoes → potato);
/// - si no, se va la «s» final (cebollas → cebolla, tomates → tomate; el
///   inglés también sale: onions → onion);
/// - nunca en «-ss» ni en palabras de 3 letras o menos (res).
String _singular(String word) {
  if (word.runes.length <= 3 || !_finalS.hasMatch(word)) return word;
  if (word.endsWith('oes')) return word.substring(0, word.length - 2);
  if (word.endsWith('ces') && !word.endsWith('ices')) {
    return '${word.substring(0, word.length - 3)}z';
  }
  final esPlural =
      word.endsWith('es') && _esPluralAfter.contains(word[word.length - 3]);
  return word.substring(0, word.length - (esPlural ? 2 : 1));
}

/// La lista de compras de [dishes]:
///
/// - cada ingrediente de cada plato, con su cantidad llevada a las porciones
///   del plato ([scaledQuantity]);
/// - los iguales, el mismo producto ([shoppingProductKey]: sin importar
///   mayúsculas, acentos, espacios, la puntuación de alrededor ni el plural)
///   en la misma unidad, en un solo renglón, sumados (hasta
///   [maxShoppingQuantity]);
/// - el mismo producto en otra unidad (3 piezas y 200 g), en otro renglón,
///   justo después: un renglón tiene una sola cantidad;
/// - cada producto con el nombre y la sección de la primera vez que aparece
///   con cantidad (si nunca la tiene, de la primera vez);
/// - un «q.b.» una sola vez, y ninguna si el mismo producto ya va con
///   cantidad;
/// - por sección, en el orden del súper ([ShoppingSection]), y dentro de cada
///   una en el orden en que aparecen;
/// - como mucho [maxShoppingItems] renglones.
ShoppingList buildShoppingList(Iterable<WeekMenuDish> dishes) {
  final products = <String, _Product>{};
  var order = 0;
  for (final dish in dishes) {
    for (final ingredient in dish.recipe.ingredients) {
      final name = normalizeRecipeText(ingredient.name);
      if (name.isEmpty) continue;
      final seen = (name: name, section: ingredient.section, order: order++);
      final product = products.putIfAbsent(
        shoppingProductKey(name),
        () => _Product(seen),
      );
      final amount = ingredient.amount;
      if (amount == null) continue;
      product.firstWithQuantity ??= seen;
      final quantity = scaledQuantity(
        amount.quantity,
        amount.unit,
        dish.portions,
      );
      product.quantities.update(
        amount.unit,
        (sum) => (sum + quantity).clamp(1, maxShoppingQuantity),
        ifAbsent: () => quantity.clamp(1, maxShoppingQuantity),
      );
    }
  }
  final sorted = products.values.toList()
    ..sort((a, b) {
      final bySection = a.listed.section.index.compareTo(
        b.listed.section.index,
      );
      return bySection != 0
          ? bySection
          : a.listed.order.compareTo(b.listed.order);
    });
  final items = [
    for (final product in sorted)
      if (product.quantities.isEmpty)
        ShoppingItem(name: product.listed.name, section: product.listed.section)
      else
        for (final MapEntry(key: unit, value: quantity)
            in product.quantities.entries)
          ShoppingItem(
            name: product.listed.name,
            section: product.listed.section,
            amount: (quantity: quantity, unit: unit),
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

/// Una vez que aparece un ingrediente: con qué nombre, en qué sección y en
/// qué lugar de los platos.
typedef _Seen = ({String name, ShoppingSection section, int order});

/// Lo que se va juntando de un producto.
final class _Product {
  _Product(this.first);

  /// La primera vez que aparece.
  final _Seen first;

  /// La primera vez que aparece con cantidad.
  _Seen? firstWithQuantity;

  /// Lo sumado en cada unidad, en el orden en que aparecen.
  final Map<IngredientUnit, int> quantities = {};

  /// De dónde salen el nombre, la sección y el lugar de sus renglones: la
  /// primera vez con cantidad (sus «q.b.» no quedan) o, si nunca la tiene, la
  /// primera.
  _Seen get listed => firstWithQuantity ?? first;
}

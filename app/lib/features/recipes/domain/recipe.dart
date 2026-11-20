// Catálogo de platos de la cocinera (M4a): cada plato con su nombre en
// italiano (el principal: lo ven los clientes sin traducción) y, si quiere, en
// español e inglés; los alérgenos (los 14 del Reg. UE 1169/2011), la dieta,
// la temporada, la conservación y los ingredientes con su cantidad para 4
// porciones. Dart puro.
//
// La base (migración 20261116170000_recipe_catalog.sql) guarda un plato entero
// con save_recipe: la receta, sus alérgenos y sus ingredientes en una sola
// transacción, así nunca queda con los alérgenos a medio guardar. La lista de
// compras de una sesión sale de los ingredientes (PR de la lista de compras):
// es la que la cocinera le manda al cliente, que hace la compra.
//
// Las notas del plato son de la cocinera: viven en recipe_notes, que el
// cliente no lee (en recipes las vería: la RLS filtra filas, no columnas), y
// nunca se loguean ni salen en toString.
//
// La descripción corta (en italiano y, si quiere, en español e inglés) es
// pública: la web la muestra al lado del nombre en la pestaña «Menù» del
// formulario de pedido (migración 20261119150000_menu_web.sql). Sin la
// italiana, el plato no sale en la web.
//
// Desde el 20/11/2026 Evelyn escribe el nombre y la descripción en español y
// el italiano y el inglés los completa la traducción automática (POST
// chef/translate, contrato chef-api.md §12). recipes.auto_translated guarda
// qué campos llenó el traductor y ella no tocó a mano (migración
// 20261120090000_recipe_translations.sql): [Recipe.autoTranslated].
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

part 'recipe.freezed.dart';

/// Porciones para las que se escriben las cantidades de los ingredientes.
const int recipeBasePortions = 4;

/// Límites de la base (checks de recipes y recipe_ingredients).
const int maxRecipeNameLength = 120;
const int maxRecipeDescriptionLength = 200;
const int maxIngredientNameLength = 80;
const int maxIngredients = 50;
const int maxIngredientQuantity = 100000;

/// Largo máximo de las notas (la base no lo limita: es para el campo).
const int maxRecipeNotesLength = 500;

/// Conservación por defecto (los de la tabla) y topes del formulario: la base
/// acepta más, pero 300 días en la heladera es un error de tipeo.
const int defaultFridgeDays = 3;
const int maxFridgeDays = 30;
const int defaultFreezerDays = 60;
const int maxFreezerDays = 365;

/// `shopping_section`: la sección del súper, en el orden del recorrido. La
/// lista de compras agrupa en este orden.
enum ShoppingSection {
  produce('produce'),
  meatFish('meat_fish'),
  dairyEggs('dairy_eggs'),
  bakery('bakery'),
  pantry('pantry'),
  frozen('frozen'),
  other('other');

  const ShoppingSection(this.dbValue);

  /// El valor del enum en la base.
  final String dbValue;
}

/// `ingredient_unit`: gramos, mililitros o piezas (el nombre es el de la base).
enum IngredientUnit { g, ml, pcs }

/// Cantidad entera para [recipeBasePortions] porciones, en [unit].
typedef IngredientAmount = ({int quantity, IngredientUnit unit});

/// Un ingrediente de un plato. Sin [amount] es «q.b.» (cantidad a gusto, como
/// la sal).
@Freezed(fromJson: false, toJson: false)
abstract class RecipeIngredient with _$RecipeIngredient {
  const factory RecipeIngredient({
    required String name,
    @Default(ShoppingSection.other) ShoppingSection section,
    IngredientAmount? amount,
  }) = _RecipeIngredient;

  const RecipeIngredient._();

  bool get toTaste => amount == null;
}

/// Un campo que llena la traducción automática (del español): los valores de
/// `recipes.auto_translated`, en el orden en que los guarda save_recipe. El
/// español es la fuente y nunca está.
enum TranslatedField {
  nameIt('name_it'),
  descriptionIt('description_it'),
  nameEn('name_en'),
  descriptionEn('description_en');

  const TranslatedField(this.dbValue);

  /// El valor en la base.
  final String dbValue;

  /// Un nombre (sale del nombre en español); si no, una descripción.
  bool get isName => this == nameIt || this == nameEn;
}

/// Si un plato sale en el menú de la web (get_public_menu): tiene que estar
/// activo, en el catálogo y con la descripción en italiano. La lista solo trae
/// platos del catálogo (`catalog_visible`).
enum RecipeWebStatus {
  /// Sale en la web.
  published,

  /// Activo, pero sin descripción en italiano: no sale.
  missingDescription,

  /// Desactivado: no sale (la lista ya lo marca).
  inactive,
}

/// Un plato del catálogo. [allergens] va en el orden del enum, sin repetir;
/// [seasonMonths], en orden y sin repetir (null = todo el año).
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class Recipe with _$Recipe {
  const factory Recipe({
    required String id,
    required String nameIt,
    String? nameEs,
    String? nameEn,

    /// Descripción corta para la web (null = sin descripción). Sin la
    /// italiana el plato no sale en la web; sin la española o la inglesa, la
    /// web muestra la italiana.
    String? descriptionIt,
    String? descriptionEs,
    String? descriptionEn,

    /// Los campos que llenó la traducción automática y la cocinera no tocó a
    /// mano: si cambia el español, se vuelven a traducir. Siempre con texto, y
    /// con el español del que salen ([sourceOf]).
    @Default(<TranslatedField>{}) Set<TranslatedField> autoTranslated,
    Diet? diet,
    @Default(<Allergen>[]) List<Allergen> allergens,
    List<int>? seasonMonths,
    @Default(defaultFridgeDays) int fridgeDays,
    @Default(false) bool freezable,
    @Default(defaultFreezerDays) int freezerDays,

    /// De la cocinera: nunca se loguean.
    String? notes,

    /// false = desactivado: no se ofrece ni entra en menús nuevos. Un plato
    /// nunca se borra (session_menu lo protege).
    @Default(true) bool active,
    @Default(<RecipeIngredient>[]) List<RecipeIngredient> ingredients,
  }) = _Recipe;

  const Recipe._();

  /// Una fila de PostgREST seleccionada con [recipeColumns]. Lanza
  /// [FormatException] si está rota o trae un valor que esta versión no
  /// conoce: descartarlo en silencio lo borraría al guardar (save_recipe
  /// reemplaza enteros los alérgenos y los ingredientes).
  factory Recipe.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final nameIt = json['name_it'];
    final fridgeDays = json['fridge_days'];
    final freezable = json['freezable'];
    final freezerDays = json['freezer_days'];
    final active = json['active'];
    final allergens = json['allergens'];
    final ingredients = json['ingredients'];
    if (id is! String ||
        id.isEmpty ||
        nameIt is! String ||
        fridgeDays is! int ||
        freezable is! bool ||
        freezerDays is! int ||
        active is! bool ||
        allergens is! List ||
        ingredients is! List) {
      throw const FormatException('Fila de recipes inválida');
    }
    return Recipe(
      id: id,
      nameIt: nameIt,
      nameEs: _optionalText(json['name_es']),
      nameEn: _optionalText(json['name_en']),
      descriptionIt: _optionalText(json['description_it']),
      descriptionEs: _optionalText(json['description_es']),
      descriptionEn: _optionalText(json['description_en']),
      autoTranslated: _autoTranslatedFromJson(json['auto_translated']),
      diet: _dietFromJson(json['diet']),
      allergens: _allergensFromJson(allergens),
      seasonMonths: _monthsFromJson(json['season_months']),
      fridgeDays: fridgeDays,
      freezable: freezable,
      freezerDays: freezerDays,
      notes: _notesFromJson(json['notes']),
      active: active,
      ingredients: _ingredientsFromJson(ingredients),
    );
  }

  /// El texto de [field] (null = vacío).
  String? textOf(TranslatedField field) => switch (field) {
    TranslatedField.nameIt => nameIt,
    TranslatedField.descriptionIt => descriptionIt,
    TranslatedField.nameEn => nameEn,
    TranslatedField.descriptionEn => descriptionEn,
  };

  /// El español del que sale [field]: el nombre o la descripción (null =
  /// vacío).
  String? sourceOf(TranslatedField field) =>
      field.isName ? nameEs : descriptionEs;

  /// Si sale en el menú de la web.
  RecipeWebStatus get webStatus {
    if (!active) return RecipeWebStatus.inactive;
    return descriptionIt == null
        ? RecipeWebStatus.missingDescription
        : RecipeWebStatus.published;
  }

  @override
  String toString() => 'Recipe($id)';
}

/// Columnas que la app lee de `recipes`, con los alérgenos, los ingredientes y
/// las notas embebidos (FK compuestas `(recipe_id, chef_id) → recipes (id,
/// chef_id)`). Las notas llegan como una lista de cero o una fila.
const String recipeColumns =
    'id, name_it, name_es, name_en, description_it, description_es, '
    'description_en, auto_translated, diet, season_months, fridge_days, '
    'freezable, freezer_days, active, '
    'allergens:recipe_allergens(allergen), '
    'ingredients:recipe_ingredients(position, name, section, quantity, unit), '
    'notes:recipe_notes(notes)';

/// El argumento `p` de save_recipe: el plato entero. Los ingredientes van en
/// orden (la base les pone la posición). Nunca lleva `active` ni
/// `catalog_visible`: save_recipe no toca una clave que no viene, así guardar
/// no reactiva un plato ni pasa una receta de evento al catálogo. Las
/// descripciones van siempre (null = sin descripción: borra la que había), y
/// también `auto_translated`, que save_recipe reemplaza en cada guardado: solo
/// los campos con texto y con el español del que salen (save_recipe rechaza un
/// campo marcado sin texto, un nombre marcado sin `name_es` y una descripción
/// marcada sin `description_es`).
Map<String, Object?> recipeSavePayload(Recipe recipe) => {
  'id': recipe.id,
  'name_it': recipe.nameIt,
  'name_es': recipe.nameEs,
  'name_en': recipe.nameEn,
  'description_it': recipe.descriptionIt,
  'description_es': recipe.descriptionEs,
  'description_en': recipe.descriptionEn,
  'auto_translated': [
    for (final field in TranslatedField.values)
      if (recipe.autoTranslated.contains(field) &&
          recipe.textOf(field) != null &&
          recipe.sourceOf(field) != null)
        field.dbValue,
  ],
  'diet': recipe.diet?.name,
  'season_months': recipe.seasonMonths,
  'fridge_days': recipe.fridgeDays,
  'freezable': recipe.freezable,
  'freezer_days': recipe.freezerDays,
  'notes': recipe.notes,
  'allergens': [for (final allergen in recipe.allergens) allergen.name],
  'ingredients': [
    for (final ingredient in recipe.ingredients)
      {
        'name': ingredient.name,
        'section': ingredient.section.dbValue,
        'quantity': ingredient.amount?.quantity,
        'unit': ingredient.amount?.unit.name,
      },
  ],
};

String? _optionalText(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('Texto inválido');
  return value.isEmpty ? null : value;
}

/// `auto_translated`: una lista de textos (sin la columna, ninguno). Un
/// campo que esta versión no conoce se descarta: queda como escrito a mano,
/// así nunca se traduce encima de él.
Set<TranslatedField> _autoTranslatedFromJson(Object? value) {
  if (value == null) return const {};
  if (value is! List || value.any((field) => field is! String)) {
    throw const FormatException('auto_translated inválido');
  }
  return {
    for (final field in TranslatedField.values)
      if (value.contains(field.dbValue)) field,
  };
}

/// Las notas embebidas de recipe_notes: PostgREST las manda como una lista
/// (sin notas, vacía); también se acepta la fila sola, por si un día las
/// detecta como uno a uno.
String? _notesFromJson(Object? value) {
  final row = switch (value) {
    null || [] => null,
    [final only] => only,
    List() => throw const FormatException('Más de una fila de recipe_notes'),
    _ => value,
  };
  if (row == null) return null;
  if (row is! Map) throw const FormatException('Fila de recipe_notes inválida');
  return _optionalText(row['notes']);
}

T _known<T extends Enum>(List<T> values, Object? name, String what) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('$what desconocido');
}

Diet? _dietFromJson(Object? value) =>
    value == null ? null : _known(Diet.values, value, 'Dieta');

List<Allergen> _allergensFromJson(List<dynamic> rows) {
  final found = <Allergen>{};
  for (final row in rows) {
    if (row is! Map) throw const FormatException('Fila de recipe_allergens inválida');
    found.add(_known(Allergen.values, row['allergen'], 'Alérgeno'));
  }
  return [
    for (final allergen in Allergen.values)
      if (found.contains(allergen)) allergen,
  ];
}

List<int>? _monthsFromJson(Object? value) {
  if (value == null) return null;
  if (value is! List || value.any((m) => m is! int || m < 1 || m > 12)) {
    throw const FormatException('Meses inválidos');
  }
  return normalizeSeasonMonths(value.cast<int>());
}

List<RecipeIngredient> _ingredientsFromJson(List<dynamic> rows) {
  final byPosition = <(int, RecipeIngredient)>[];
  for (final row in rows) {
    if (row is! Map) throw const FormatException('Fila de recipe_ingredients inválida');
    final position = row['position'];
    final name = row['name'];
    final quantity = row['quantity'];
    final unit = row['unit'];
    if (position is! int || name is! String || (quantity != null && quantity is! int)) {
      throw const FormatException('Fila de recipe_ingredients inválida');
    }
    if ((quantity == null) != (unit == null)) {
      throw const FormatException('Cantidad sin unidad');
    }
    final section = ShoppingSection.values.where((s) => s.dbValue == row['section']);
    if (section.isEmpty) throw const FormatException('Sección desconocida');
    byPosition.add((
      position,
      RecipeIngredient(
        name: name,
        section: section.single,
        amount: quantity is int
            ? (quantity: quantity, unit: _known(IngredientUnit.values, unit, 'Unidad'))
            : null,
      ),
    ));
  }
  byPosition.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, ingredient) in byPosition) ingredient];
}

/// Espacios (de cualquier tipo) y caracteres de control, que la base no
/// acepta en un nombre ni en una descripción: un salto de línea rompería la
/// lista copiada a Notas o WhatsApp.
final RegExp _spaceOrControl = RegExp(r'[\s\u0000-\u001f\u007f-\u009f  ]+');

/// Un nombre (o una descripción) como lo guarda la base: sin espacios al
/// borde, sin caracteres de control y con un solo espacio entre palabras.
String normalizeRecipeText(String text) =>
    text.replaceAll(_spaceOrControl, ' ').trim();

/// Largo de [text] como lo cuenta Postgres (char_length): por caracteres
/// (code points), no por unidades UTF-16 ni por lo que se ve como una letra
/// (🍝 cuenta uno; una bandera o una «é» con el acento aparte, dos).
int textLength(String text) => text.runes.length;

/// Largo de un nombre o una descripción como lo valida la base: el texto ya
/// normalizado ([normalizeRecipeText]) contado con [textLength]. Lo usan la
/// validación del formulario y el contador del editor: cuentan lo mismo.
int recipeTextLength(String raw) => textLength(normalizeRecipeText(raw));

/// Los meses de una temporada, en orden y sin repetir. Ninguno o los 12 es
/// «todo el año»: null. Lanza [RangeError] con un mes fuera de 1 a 12.
List<int>? normalizeSeasonMonths(Iterable<int>? months) {
  if (months == null) return null;
  final set = months.toSet();
  for (final month in set) {
    RangeError.checkValueInInterval(month, 1, 12, 'month');
  }
  if (set.isEmpty || set.length == 12) return null;
  return set.toList()..sort();
}

/// El plato se ofrece en [month] (1 a 12).
bool isInSeason(List<int>? seasonMonths, int month) =>
    seasonMonths == null || seasonMonths.contains(month);

/// Un tramo de meses seguidos; [first] puede ser mayor que [last] si cruza el
/// año (de noviembre a febrero).
typedef MonthRange = ({int first, int last});

/// Los tramos de meses seguidos de [months], con la vuelta de diciembre a
/// enero: {10, 11, 12, 1, 2} es un solo tramo, de octubre a febrero. En orden
/// por el primer mes (el que cruza el año, al final).
List<MonthRange> seasonRanges(List<int> months) {
  final set = months.toSet();
  final runs = <MonthRange>[];
  int? start;
  var previous = 0;
  for (var month = 1; month <= 12; month++) {
    if (set.contains(month)) {
      start ??= month;
      previous = month;
    } else if (start != null) {
      runs.add((first: start, last: previous));
      start = null;
    }
  }
  if (start != null) runs.add((first: start, last: previous));
  if (runs.length > 1 && runs.first.first == 1 && runs.last.last == 12) {
    return [
      ...runs.sublist(1, runs.length - 1),
      (first: runs.last.first, last: runs.first.last),
    ];
  }
  return runs;
}

/// Alérgenos que una dieta no admite: un plato vegano no lleva productos
/// animales y uno vegetariano no lleva pescado ni mariscos. Un plato marcado
/// así se le ofrecería a una clienta con esa dieta.
const Map<Diet, Set<Allergen>> allergensExcludedByDiet = {
  Diet.vegetarian: {Allergen.crustaceans, Allergen.fish, Allergen.molluscs},
  Diet.vegan: {
    Allergen.crustaceans,
    Allergen.eggs,
    Allergen.fish,
    Allergen.milk,
    Allergen.molluscs,
  },
};

/// Los alérgenos de [allergens] que la dieta [diet] no admite, en el orden
/// del enum.
List<Allergen> dietConflicts(Diet? diet, Iterable<Allergen> allergens) {
  if (diet == null) return const [];
  final excluded = allergensExcludedByDiet[diet]!;
  final present = allergens.toSet();
  return [
    for (final allergen in Allergen.values)
      if (present.contains(allergen) && excluded.contains(allergen)) allergen,
  ];
}

const Map<String, String> _withoutAccent = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y',
};

/// [text] para comparar en una búsqueda: en minúsculas, sin acentos y con un
/// solo espacio entre palabras.
String foldForSearch(String text) {
  final buffer = StringBuffer();
  for (final rune in normalizeRecipeText(text).toLowerCase().runes) {
    // Acentos sueltos (combinantes), por si el teclado no los compuso.
    if (rune >= 0x0300 && rune <= 0x036f) continue;
    final char = String.fromCharCode(rune);
    buffer.write(_withoutAccent[char] ?? char);
  }
  return buffer.toString();
}

/// Cada palabra de [query] está en alguno de los nombres del plato (italiano,
/// español o inglés), sin importar mayúsculas ni acentos. Vacía: todos.
bool recipeMatchesQuery(Recipe recipe, String query) {
  final words = foldForSearch(query).split(' ').where((w) => w.isNotEmpty);
  final names = [
    recipe.nameIt,
    ?recipe.nameEs,
    ?recipe.nameEn,
  ].map(foldForSearch).toList();
  return words.every((word) => names.any((name) => name.contains(word)));
}

/// Lo que muestra la lista del catálogo.
final class RecipeCatalogView {
  const RecipeCatalogView({
    required this.active,
    required this.inactive,
    required this.total,
  });

  /// Los activos que coinciden con la búsqueda, por nombre en italiano.
  final List<Recipe> active;

  /// Los desactivados que coinciden, igual: van al final.
  final List<Recipe> inactive;

  /// Todos los platos del catálogo, coincidan o no (0 = catálogo vacío).
  final int total;

  bool get isEmpty => active.isEmpty && inactive.isEmpty;
}

/// Ordena y filtra [recipes] para la lista: activos primero, cada grupo por
/// nombre en italiano.
RecipeCatalogView recipeCatalogView(
  Iterable<Recipe> recipes, {
  String query = '',
}) {
  final all = recipes.toList();
  final matching = all.where((r) => recipeMatchesQuery(r, query)).toList()
    ..sort(_byItalianName);
  return RecipeCatalogView(
    active: [for (final r in matching) if (r.active) r],
    inactive: [for (final r in matching) if (!r.active) r],
    total: all.length,
  );
}

int _byItalianName(Recipe a, Recipe b) {
  final byName = foldForSearch(a.nameIt).compareTo(foldForSearch(b.nameIt));
  return byName != 0 ? byName : a.id.compareTo(b.id);
}

/// Ya hay un plato (que no sea [exceptId]) con el nombre en italiano
/// [nameIt], sin importar mayúsculas, acentos ni espacios.
bool hasRecipeNamed(
  Iterable<Recipe> recipes,
  String nameIt, {
  String? exceptId,
}) {
  final wanted = foldForSearch(nameIt);
  if (wanted.isEmpty) return false;
  return recipes.any((r) => r.id != exceptId && foldForSearch(r.nameIt) == wanted);
}

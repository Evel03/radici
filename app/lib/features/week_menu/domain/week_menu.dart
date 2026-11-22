// Menú de una semana (SPEC 5.8, paso 4): una sesión de una reserva, ligada a
// su pedido por `sessions.request_id`. Lleva los platos del catálogo con sus
// porciones en la semana, la lista de compras para la clienta (sale de los
// ingredientes de los platos y Evelyn la edita) y una nota para ella. Dart
// puro.
//
// La base (migración 20261121090000_session_menus.sql) guarda todo junto con
// save_session_menu, con control de versión: `version` es la que la app tenía
// cargada (null = todavía no había menú), así Evelyn y un colaborador nunca se
// pisan en silencio. Los platos y la lista se reemplazan enteros.
//
// La nota y la lista llegan a la clienta (el envío es de un PR siguiente): la
// app pide no escribir datos de salud ni direcciones. Las alergias de la
// reserva no van acá: salen de la sesión (CookingSession.allergens) y solo se
// cruzan con los platos para pedir confirmación al guardar
// (`allergens_confirmed`). Nada de esto se loguea.
import 'dart:math' as math;

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

part 'week_menu.freezed.dart';

/// Límites de la base (checks de session_menu, session_shopping_items y
/// session_menus).
const int maxMenuDishes = 30;
const int maxDishPortions = 500;
const int maxShoppingItems = 150;
const int maxShoppingQuantity = 1000000;
const int maxShoppingItemNameLength = maxIngredientNameLength;
const int maxMenuNoteLength = 1000;

/// Un plato del menú: la receta (con sus nombres, foto, alérgenos, dieta e
/// ingredientes para [recipeBasePortions]) y sus porciones en la semana.
@Freezed(fromJson: false, toJson: false)
abstract class WeekMenuDish with _$WeekMenuDish {
  const factory WeekMenuDish({
    required Recipe recipe,

    /// De 1 a [maxDishPortions]: un plato puede cubrir varias comidas.
    required int portions,
  }) = _WeekMenuDish;
}

/// Un renglón de la lista de compras. Sin [amount] es «q.b.» (lo que haga
/// falta, como la sal). La cantidad queda en g, ml o piezas: la forma de
/// mostrarla (1,25 kg) es de la pantalla.
@Freezed(fromJson: false, toJson: false)
abstract class ShoppingItem with _$ShoppingItem {
  const factory ShoppingItem({
    required String name,
    @Default(ShoppingSection.other) ShoppingSection section,
    IngredientAmount? amount,
  }) = _ShoppingItem;

  const ShoppingItem._();

  bool get toTaste => amount == null;
}

/// El menú guardado de una semana. [version] null: todavía no hay menú
/// (`session_menus` no tiene la fila).
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class SavedWeekMenu with _$SavedWeekMenu {
  const factory SavedWeekMenu({
    int? version,

    /// Para la clienta (null = sin nota).
    String? note,

    /// Evelyn confirmó, al guardar, los platos que chocan con las
    /// restricciones de la reserva.
    @Default(false) bool allergensConfirmed,
    @Default(<WeekMenuDish>[]) List<WeekMenuDish> dishes,
    @Default(<ShoppingItem>[]) List<ShoppingItem> items,
  }) = _SavedWeekMenu;

  const SavedWeekMenu._();

  /// Una fila de `sessions` seleccionada con [weekMenuColumns]. Lanza
  /// [FormatException] si está rota o trae un valor que esta versión no
  /// conoce (descartarlo lo borraría al guardar: los platos y la lista se
  /// reemplazan enteros).
  factory SavedWeekMenu.fromSessionRow(Map<String, dynamic> json) {
    final menu = _single(json['menu']);
    final dishes = json['dishes'];
    final items = json['items'];
    if (dishes is! List || items is! List) {
      throw const FormatException('Menú inválido');
    }
    int? version;
    String? note;
    var confirmed = false;
    if (menu != null) {
      final v = menu['version'];
      final n = menu['note'];
      final c = menu['allergens_confirmed'];
      if (v is! int || (n != null && n is! String) || c is! bool) {
        throw const FormatException('Fila de session_menus inválida');
      }
      final text = n as String?;
      version = v;
      note = text == null || text.isEmpty ? null : text;
      confirmed = c;
    }
    return SavedWeekMenu(
      version: version,
      note: note,
      allergensConfirmed: confirmed,
      dishes: _dishesFromJson(dishes),
      items: _itemsFromJson(items),
    );
  }

  bool get exists => version != null;

  /// Lo guardado es [save] (los platos con sus porciones, la lista, la nota y
  /// la confirmación): un guardado que el servidor ya tenía.
  bool matches(WeekMenuSave save) =>
      note == save.note &&
      allergensConfirmed == save.allergensConfirmed &&
      _sameDishes(dishes, save.dishes) &&
      _sameList(items, save.items);

  /// Solo la versión: la nota es para la clienta.
  @override
  String toString() => 'SavedWeekMenu(v$version)';
}

/// Cuántos platos y renglones tiene el menú de una semana, para la ficha de
/// la sesión y la reserva.
@Freezed(fromJson: false, toJson: false)
abstract class WeekMenuSummary with _$WeekMenuSummary {
  const factory WeekMenuSummary({
    /// Ya se guardó alguna vez (tiene la fila de `session_menus`).
    @Default(false) bool saved,
    @Default(0) int dishes,
    @Default(0) int items,
  }) = _WeekMenuSummary;
}

/// Lo que se guarda con save_session_menu.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class WeekMenuSave with _$WeekMenuSave {
  const factory WeekMenuSave({
    required String sessionId,

    /// La versión cargada (null = todavía no había menú).
    int? version,

    /// Ya normalizada ([normalizeMenuNote]); null = sin nota.
    String? note,
    required bool allergensConfirmed,
    required List<WeekMenuDish> dishes,
    required List<ShoppingItem> items,
  }) = _WeekMenuSave;

  const WeekMenuSave._();

  @override
  String toString() => 'WeekMenuSave($sessionId, v$version)';
}

/// Columnas de `recipes` que lee el menú: lo que muestra (nombres, foto,
/// alérgenos, dieta, si está activo) y los ingredientes de la lista. Sin las
/// notas de la cocinera ni las descripciones: estos platos solo se muestran
/// (un plato se guarda desde el catálogo, que sí las tiene).
const String menuRecipeColumns =
    'id, name_it, name_es, name_en, diet, fridge_days, freezable, '
    'freezer_days, active, photo_id, '
    'allergens:recipe_allergens(allergen), '
    'ingredients:recipe_ingredients(position, name, section, quantity, unit)';

/// Columnas que la app lee de `sessions` para el menú de una semana: la fila
/// de `session_menus`, los platos (`session_menu`, con su receta embebida por
/// la FK `(recipe_id, chef_id) → recipes`) y la lista
/// (`session_shopping_items`). Una sola consulta: todo sale del mismo
/// momento, así la versión es la de esos platos y esa lista.
const String weekMenuColumns =
    'id, '
    'menu:session_menus(version, note, allergens_confirmed), '
    'dishes:session_menu(position, portions, recipe:recipes($menuRecipeColumns)), '
    'items:session_shopping_items(position, name, section, quantity, unit)';

/// Columnas de `sessions` para contar los platos y los renglones de cada
/// semana (sin traer las recetas).
const String weekMenuSummaryColumns =
    'id, '
    'menu:session_menus(version), '
    'dishes:session_menu(recipe_id), '
    'items:session_shopping_items(position)';

/// Una fila de `sessions` seleccionada con [weekMenuSummaryColumns]. Lanza
/// [FormatException] si está rota.
WeekMenuSummary weekMenuSummaryFromRow(Map<String, dynamic> json) {
  final dishes = json['dishes'];
  final items = json['items'];
  if (dishes is! List || items is! List) {
    throw const FormatException('Menú inválido');
  }
  return WeekMenuSummary(
    saved: _single(json['menu']) != null,
    dishes: dishes.length,
    items: items.length,
  );
}

/// El argumento `p` de save_session_menu. Siempre con todas las claves: la
/// nota (null la borra) y la confirmación (false si no hay choques), así lo
/// guardado nunca queda con una confirmación de otro menú. Los platos y los
/// renglones van en orden (la base les pone la posición).
Map<String, Object?> weekMenuSavePayload(WeekMenuSave save) => {
  'session_id': save.sessionId,
  'version': save.version,
  'note': save.note,
  'allergens_confirmed': save.allergensConfirmed,
  'dishes': [
    for (final dish in save.dishes)
      {'recipe_id': dish.recipe.id, 'portions': dish.portions},
  ],
  'items': [
    for (final item in save.items)
      {
        'name': item.name,
        'section': item.section.dbValue,
        'quantity': item.amount?.quantity,
        'unit': item.amount?.unit.name,
      },
  ],
};

// ---------------------------------------------------------------------
// Choques con las restricciones de la reserva
// ---------------------------------------------------------------------

/// Lo que la reserva no admite: los alérgenos a evitar y las dietas
/// (CookingSession.allergens y CookingSession.diets). Dato de salud.
typedef MenuRestrictions = ({List<Allergen> allergens, List<Diet> diets});

/// Las restricciones de la reserva de [session].
MenuRestrictions menuRestrictionsOf(CookingSession session) =>
    (allergens: session.allergens, diets: session.diets);

/// Por qué un plato choca con las restricciones de la reserva: los alérgenos
/// del plato que la reserva evita y las dietas de la reserva que el plato no
/// cumple, en el orden de sus enums.
@immutable
final class DishConflict {
  const DishConflict({
    this.allergens = const <Allergen>[],
    this.diets = const <Diet>[],
  });

  final List<Allergen> allergens;
  final List<Diet> diets;

  bool get isEmpty => allergens.isEmpty && diets.isEmpty;

  bool get isNotEmpty => !isEmpty;

  @override
  bool operator ==(Object other) =>
      other is DishConflict &&
      _sameEnums(other.allergens, allergens) &&
      _sameEnums(other.diets, diets);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(allergens), Object.hashAll(diets));

  @override
  String toString() => 'DishConflict(<oculto>)';
}

/// El plato con la dieta [dishDiet] cumple [diet]: uno vegano cumple las dos y
/// uno vegetariano, la vegetariana. Uno sin dieta marcada no cumple ninguna
/// (más vale preguntar: puede llevar carne).
bool dishFitsDiet(Diet? dishDiet, Diet diet) => switch (diet) {
  Diet.vegetarian => dishDiet == Diet.vegetarian || dishDiet == Diet.vegan,
  Diet.vegan => dishDiet == Diet.vegan,
};

/// Cómo choca [recipe] con [restrictions] (vacío si no choca). La nota de
/// alergias de la reserva es texto libre: no se cruza (la pantalla la muestra
/// resaltada al lado).
DishConflict dishConflict(Recipe recipe, MenuRestrictions restrictions) {
  final avoided = restrictions.allergens.toSet();
  final allergens = [
    for (final allergen in Allergen.values)
      if (avoided.contains(allergen) && recipe.allergens.contains(allergen))
        allergen,
  ];
  final wanted = restrictions.diets.toSet();
  final diets = [
    for (final diet in Diet.values)
      if (wanted.contains(diet) && !dishFitsDiet(recipe.diet, diet)) diet,
  ];
  return allergens.isEmpty && diets.isEmpty
      ? const DishConflict()
      : DishConflict(allergens: allergens, diets: diets);
}

// ---------------------------------------------------------------------
// Reglas del menú de una semana
// ---------------------------------------------------------------------

/// El menú de [status] todavía se puede armar: como en save_session_menu, una
/// sesión held o confirmed (o una vieja en shopping_done). Una cancelada,
/// cocinada o cobrada, no.
bool isMenuEditable(SessionStatus status) =>
    status == SessionStatus.held ||
    status == SessionStatus.confirmed ||
    status == SessionStatus.shoppingDone;

/// Porciones de un plato agregado: las personas de la reserva (adultos y
/// niños) por las comidas de cada día de su pedido, porque un plato cubre más
/// o menos un día. Al menos 1 y como mucho [maxDishPortions].
int defaultDishPortions(CookingSession session) {
  final people = math.max(session.people ?? 1, 1);
  final meals = math.max(session.request?.meals.length ?? 1, 1);
  return (people * meals).clamp(1, maxDishPortions);
}

/// [session] es la primera semana viva de su reserva (la de los platos que
/// eligió la clienta en la web). Una sesión sin reserva es su propia primera
/// semana.
bool isFirstWeekOfBooking(
  CookingSession session,
  Iterable<CookingSession> booking,
) {
  final live = liveBookingSessions(session, booking);
  return live.isNotEmpty && live.first.id == session.id;
}

/// Los platos que eligió la clienta en la web ([wishes], en orden), con
/// [portions] cada uno: solo los que siguen en [catalog] y están activos, sin
/// repetir y como mucho [maxMenuDishes].
List<WeekMenuDish> dishesFromWishes(
  List<String> wishes,
  Iterable<Recipe> catalog, {
  required int portions,
}) {
  final byId = {for (final recipe in catalog) recipe.id: recipe};
  final seen = <String>{};
  return [
    for (final id in wishes)
      if (byId[id] case final recipe? when recipe.active && seen.add(id))
        WeekMenuDish(recipe: recipe, portions: portions),
  ].take(maxMenuDishes).toList();
}

/// El nombre de [recipe] en [languageCode] (el idioma de la app), con el
/// italiano si falta la traducción, como el menú que eligió la clienta en el
/// detalle del pedido (MenuDish.name).
String recipeNameIn(Recipe recipe, String languageCode) =>
    switch (languageCode) {
      'es' => recipe.nameEs ?? recipe.nameIt,
      'en' => recipe.nameEn ?? recipe.nameIt,
      _ => recipe.nameIt,
    };

/// Los platos que se pueden agregar al menú: los activos de [catalog] que
/// todavía no están en [chosen] y coinciden con [query] (en cualquiera de
/// sus nombres, sin importar mayúsculas ni acentos), por su nombre en
/// [languageCode].
List<Recipe> menuPickerCandidates(
  Iterable<Recipe> catalog, {
  required Set<String> chosen,
  required String languageCode,
  String query = '',
}) {
  final candidates =
      [
        for (final recipe in catalog)
          if (recipe.active &&
              !chosen.contains(recipe.id) &&
              recipeMatchesQuery(recipe, query))
            (
              name: foldForSearch(recipeNameIn(recipe, languageCode)),
              recipe: recipe,
            ),
      ]..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        return byName != 0 ? byName : a.recipe.id.compareTo(b.recipe.id);
      });
  return [for (final candidate in candidates) candidate.recipe];
}

/// Caracteres de control salvo el salto de línea (también el tabulador), que
/// la base no acepta en la nota.
final RegExp _noteControl = RegExp(
  r'[\u0000-\u0009\u000b-\u001f\u007f-\u009f]',
);

/// La nota como la guarda la base: los saltos de línea de Windows o de un Mac
/// viejo pasan a `\n`, cualquier otro carácter de control a un espacio, sin
/// espacios ni saltos al borde. null si queda vacía.
String? normalizeMenuNote(String text) {
  final unified = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final cleaned = unified.replaceAll(_noteControl, ' ').trim();
  return cleaned.isEmpty ? null : cleaned;
}

/// Largo de la nota como lo cuenta la base (por caracteres, ya normalizada).
int menuNoteLength(String text) => textLength(normalizeMenuNote(text) ?? '');

/// Por qué no vale lo escrito en un renglón de la lista.
typedef ShoppingItemErrors = ({TextError? name, QuantityError? quantity});

/// Valida un renglón escrito a mano: el nombre (normalizado como el de un
/// ingrediente) de 1 a [maxShoppingItemNameLength] caracteres y, salvo
/// «q.b.», la cantidad de 1 a [maxShoppingQuantity].
ShoppingItemErrors validateShoppingItem({
  required String name,
  required String quantity,
  required UnitChoice unit,
}) {
  final length = recipeTextLength(name);
  final TextError? nameError = length == 0
      ? TextError.required
      : length > maxShoppingItemNameLength
      ? TextError.tooLong
      : null;
  QuantityError? quantityError;
  if (unit != UnitChoice.toTaste) {
    final value = int.tryParse(quantity.trim());
    if (quantity.trim().isEmpty) {
      quantityError = QuantityError.required;
    } else if (value == null || value < 1 || value > maxShoppingQuantity) {
      quantityError = QuantityError.outOfRange;
    }
  }
  return (name: nameError, quantity: quantityError);
}

/// El renglón escrito a mano, o null si no vale ([validateShoppingItem]).
ShoppingItem? shoppingItemFrom({
  required String name,
  required String quantity,
  required UnitChoice unit,
  required ShoppingSection section,
}) {
  final errors = validateShoppingItem(
    name: name,
    quantity: quantity,
    unit: unit,
  );
  if (errors.name != null || errors.quantity != null) return null;
  final base = unit.unit;
  return ShoppingItem(
    name: normalizeRecipeText(name),
    section: section,
    amount: base == null
        ? null
        : (quantity: int.parse(quantity.trim()), unit: base),
  );
}

// ---------------------------------------------------------------------
// Lectura de las filas
// ---------------------------------------------------------------------

/// Una fila embebida que PostgREST puede mandar sola o en una lista de cero
/// o una (según detecte la relación como uno a uno o no).
Map<Object?, Object?>? _single(Object? value) {
  final row = switch (value) {
    null || [] => null,
    [final only] => only,
    List() => throw const FormatException('Más de una fila de session_menus'),
    _ => value,
  };
  if (row == null) return null;
  if (row is! Map) {
    throw const FormatException('Fila de session_menus inválida');
  }
  return row;
}

List<WeekMenuDish> _dishesFromJson(List<dynamic> rows) {
  final byPosition = <(int, WeekMenuDish)>[];
  for (final row in rows) {
    if (row is! Map) {
      throw const FormatException('Fila de session_menu inválida');
    }
    final position = row['position'];
    final portions = row['portions'];
    final recipe = row['recipe'];
    if (position is! int || portions is! int || recipe is! Map) {
      throw const FormatException('Fila de session_menu inválida');
    }
    byPosition.add((
      position,
      WeekMenuDish(
        recipe: Recipe.fromJson(recipe.cast<String, dynamic>()),
        portions: portions,
      ),
    ));
  }
  byPosition.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, dish) in byPosition) dish];
}

List<ShoppingItem> _itemsFromJson(List<dynamic> rows) {
  final byPosition = <(int, ShoppingItem)>[];
  for (final row in rows) {
    if (row is! Map) {
      throw const FormatException('Fila de session_shopping_items inválida');
    }
    final position = row['position'];
    final name = row['name'];
    final quantity = row['quantity'];
    final unit = row['unit'];
    if (position is! int ||
        name is! String ||
        (quantity != null && quantity is! int) ||
        (quantity == null) != (unit == null)) {
      throw const FormatException('Fila de session_shopping_items inválida');
    }
    final section = ShoppingSection.values
        .where((s) => s.dbValue == row['section'])
        .firstOrNull;
    if (section == null) throw const FormatException('Sección desconocida');
    final IngredientAmount? amount;
    if (quantity is int) {
      final known = IngredientUnit.values
          .where((u) => u.name == unit)
          .firstOrNull;
      if (known == null) throw const FormatException('Unidad desconocida');
      amount = (quantity: quantity, unit: known);
    } else {
      amount = null;
    }
    byPosition.add((
      position,
      ShoppingItem(name: name, section: section, amount: amount),
    ));
  }
  byPosition.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, item) in byPosition) item];
}

bool _sameDishes(List<WeekMenuDish> a, List<WeekMenuDish> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].recipe.id != b[i].recipe.id || a[i].portions != b[i].portions) {
      return false;
    }
  }
  return true;
}

bool _sameList(List<ShoppingItem> a, List<ShoppingItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameEnums<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

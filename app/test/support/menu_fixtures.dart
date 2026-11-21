// Menús de ejemplo para los tests. Datos inventados.
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import 'recipe_fixtures.dart';

/// Un ingrediente con cantidad (para 4 porciones).
RecipeIngredient ingredient(
  String name,
  int quantity,
  IngredientUnit unit, {
  ShoppingSection section = ShoppingSection.other,
}) => RecipeIngredient(
  name: name,
  section: section,
  amount: (quantity: quantity, unit: unit),
);

/// Un ingrediente «q.b.».
RecipeIngredient toTaste(
  String name, {
  ShoppingSection section = ShoppingSection.pantry,
}) => RecipeIngredient(name: name, section: section);

/// Un plato de prueba con [ingredients] (id derivado de [n]).
Recipe dishWith(
  int n,
  List<RecipeIngredient> ingredients, {
  String? nameIt,
  bool active = true,
}) => Recipe(
  id: 'f0000000-0000-4000-8000-0000000000${n.toString().padLeft(2, '0')}',
  nameIt: nameIt ?? 'Piatto $n',
  nameEs: nameIt == null ? 'Plato $n' : null,
  active: active,
  ingredients: ingredients,
);

/// Un renglón de la lista con cantidad.
ShoppingItem item(
  String name,
  int quantity,
  IngredientUnit unit, {
  ShoppingSection section = ShoppingSection.other,
}) => ShoppingItem(
  name: name,
  section: section,
  amount: (quantity: quantity, unit: unit),
);

/// Un renglón «q.b.».
ShoppingItem toTasteItem(
  String name, {
  ShoppingSection section = ShoppingSection.pantry,
}) => ShoppingItem(name: name, section: section);

/// La lista que sale de la lasaña ([lasagne]) para [portions] porciones.
List<ShoppingItem> lasagneList(int portions) {
  int tens(int grams) => grams <= 100 ? grams : (grams + 9) ~/ 10 * 10;
  int scaled(int base) => tens((base * portions + 3) ~/ 4);
  return [
    item(
      'Carne macinata di manzo',
      scaled(400),
      IngredientUnit.g,
      section: ShoppingSection.meatFish,
    ),
    item(
      'Passata di pomodoro',
      scaled(700),
      IngredientUnit.ml,
      section: ShoppingSection.pantry,
    ),
    toTasteItem('Sale'),
  ];
}

/// Un menú guardado (versión [version]) con la lasaña para [portions] y su
/// lista.
SavedWeekMenu savedLasagneMenu({
  int version = 1,
  int portions = 4,
  String? note,
  bool allergensConfirmed = false,
  List<ShoppingItem>? items,
}) => SavedWeekMenu(
  version: version,
  note: note,
  allergensConfirmed: allergensConfirmed,
  dishes: [WeekMenuDish(recipe: lasagne(), portions: portions)],
  items: items ?? lasagneList(portions),
);

/// Fila de PostgREST de una receta como la embebe [weekMenuColumns]
/// ([menuRecipeColumns]: sin notas ni descripciones), la de la lasaña.
Map<String, dynamic> menuRecipeRow({String id = lasagneId}) => {
  'id': id,
  'name_it': 'Lasagne alla bolognese',
  'name_es': 'Lasaña a la boloñesa',
  'name_en': 'Lasagne Bolognese',
  'diet': null,
  'fridge_days': 3,
  'freezable': true,
  'freezer_days': 60,
  'active': true,
  'photo_id': null,
  'allergens': const [
    {'allergen': 'milk'},
    {'allergen': 'gluten'},
    {'allergen': 'celery'},
    {'allergen': 'eggs'},
  ],
  'ingredients': const [
    {
      'position': 2,
      'name': 'Passata di pomodoro',
      'section': 'pantry',
      'quantity': 700,
      'unit': 'ml',
    },
    {
      'position': 1,
      'name': 'Carne macinata di manzo',
      'section': 'meat_fish',
      'quantity': 400,
      'unit': 'g',
    },
    {
      'position': 3,
      'name': 'Sale',
      'section': 'pantry',
      'quantity': null,
      'unit': null,
    },
  ],
};

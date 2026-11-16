// Platos de ejemplo para los tests (los del seed de Evelyn). Datos inventados.
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

const String lasagneId = 'a0000000-0000-4000-8000-000000000001';
const String risottoId = 'a0000000-0000-4000-8000-000000000002';
const String minestroneId = 'a0000000-0000-4000-8000-000000000003';
const String frittataId = 'a0000000-0000-4000-8000-000000000010';

/// Fila de PostgREST como la devuelve `select(recipeColumns)`: los alérgenos
/// y los ingredientes llegan embebidos, en cualquier orden.
Map<String, dynamic> recipeRow({
  String id = lasagneId,
  Object? nameIt = 'Lasagne alla bolognese',
  Object? nameEs = 'Lasaña a la boloñesa',
  Object? nameEn = 'Lasagne Bolognese',
  Object? diet,
  Object? seasonMonths,
  Object? fridgeDays = 3,
  Object? freezable = true,
  Object? freezerDays = 60,
  Object? notes,
  Object? active = true,
  Object? allergens = const [
    {'allergen': 'milk'},
    {'allergen': 'gluten'},
    {'allergen': 'celery'},
    {'allergen': 'eggs'},
  ],
  Object? ingredients = const [
    {'position': 2, 'name': 'Passata di pomodoro', 'section': 'pantry', 'quantity': 700, 'unit': 'ml'},
    {'position': 1, 'name': 'Carne macinata di manzo', 'section': 'meat_fish', 'quantity': 400, 'unit': 'g'},
    {'position': 3, 'name': 'Sale', 'section': 'pantry', 'quantity': null, 'unit': null},
  ],
}) => {
  'id': id,
  'name_it': nameIt,
  'name_es': nameEs,
  'name_en': nameEn,
  'diet': diet,
  'season_months': seasonMonths,
  'fridge_days': fridgeDays,
  'freezable': freezable,
  'freezer_days': freezerDays,
  'notes': notes,
  'active': active,
  'allergens': allergens,
  'ingredients': ingredients,
};

Recipe lasagne() => const Recipe(
  id: lasagneId,
  nameIt: 'Lasagne alla bolognese',
  nameEs: 'Lasaña a la boloñesa',
  nameEn: 'Lasagne Bolognese',
  allergens: [Allergen.gluten, Allergen.eggs, Allergen.milk, Allergen.celery],
  freezable: true,
  ingredients: [
    RecipeIngredient(
      name: 'Carne macinata di manzo',
      section: ShoppingSection.meatFish,
      amount: (quantity: 400, unit: IngredientUnit.g),
    ),
    RecipeIngredient(
      name: 'Passata di pomodoro',
      section: ShoppingSection.pantry,
      amount: (quantity: 700, unit: IngredientUnit.ml),
    ),
    RecipeIngredient(name: 'Sale', section: ShoppingSection.pantry),
  ],
);

Recipe risotto() => const Recipe(
  id: risottoId,
  nameIt: 'Risotto ai funghi porcini',
  nameEs: 'Risotto de hongos porcini',
  nameEn: 'Porcini mushroom risotto',
  diet: Diet.vegetarian,
  allergens: [Allergen.milk, Allergen.celery, Allergen.sulphites],
  seasonMonths: [9, 10, 11],
  fridgeDays: 2,
  notes: 'Si può fare senza burro e parmigiano.',
);

Recipe minestrone() => const Recipe(
  id: minestroneId,
  nameIt: 'Minestrone di verdure',
  nameEs: 'Minestrone de verduras',
  diet: Diet.vegan,
  allergens: [Allergen.celery],
  seasonMonths: [1, 2, 3, 4, 10, 11, 12],
  fridgeDays: 4,
  freezable: true,
  freezerDays: 90,
);

Recipe frittata() => const Recipe(
  id: frittataId,
  nameIt: 'Frittata di zucchine',
  nameEs: 'Tortilla de zapallitos',
  diet: Diet.vegetarian,
  allergens: [Allergen.eggs, Allergen.milk],
  seasonMonths: [5, 6, 7, 8, 9],
  fridgeDays: 2,
  active: false,
);

/// Tres activos y uno desactivado, desordenados.
List<Recipe> sampleRecipes() => [risotto(), frittata(), lasagne(), minestrone()];

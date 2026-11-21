// Platos de ejemplo para los tests (los del seed de Evelyn). Datos inventados.
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

const String lasagneId = 'a0000000-0000-4000-8000-000000000001';
const String risottoId = 'a0000000-0000-4000-8000-000000000002';
const String minestroneId = 'a0000000-0000-4000-8000-000000000003';
const String frittataId = 'a0000000-0000-4000-8000-000000000010';
const String milanesaId = 'a0000000-0000-4000-8000-000000000004';
const String pastelId = 'a0000000-0000-4000-8000-000000000005';

/// Fila de PostgREST como la devuelve `select(recipeColumns)`: los alérgenos
/// y los ingredientes llegan embebidos, en cualquier orden, y las notas como
/// una lista de cero o una fila de recipe_notes ([notes] de texto se arma así;
/// otro valor va tal cual). Las descripciones por defecto son las de
/// [lasagne], sin campos de la traducción automática.
Map<String, dynamic> recipeRow({
  String id = lasagneId,
  Object? nameIt = 'Lasagne alla bolognese',
  Object? nameEs = 'Lasaña a la boloñesa',
  Object? nameEn = 'Lasagne Bolognese',
  Object? descriptionIt = lasagneDescriptionIt,
  Object? descriptionEs = lasagneDescriptionEs,
  Object? descriptionEn,
  Object? autoTranslated = const <String>[],
  Object? diet,
  Object? seasonMonths,
  Object? fridgeDays = 3,
  Object? freezable = true,
  Object? freezerDays = 60,
  Object? notes,
  Object? active = true,
  Object? photoId,
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
  'description_it': descriptionIt,
  'description_es': descriptionEs,
  'description_en': descriptionEn,
  'auto_translated': autoTranslated,
  'diet': diet,
  'season_months': seasonMonths,
  'fridge_days': fridgeDays,
  'freezable': freezable,
  'freezer_days': freezerDays,
  'notes': switch (notes) {
    null => const <Object>[],
    String() => [
      {'notes': notes},
    ],
    _ => notes,
  },
  'active': active,
  'photo_id': photoId,
  'allergens': allergens,
  'ingredients': ingredients,
};

/// La descripción de la web de [lasagne] (sin la inglesa: la web usa esta).
const String lasagneDescriptionIt = 'Ragù cotto piano e besciamella fatta in casa.';
const String lasagneDescriptionEs = 'Ragú cocido despacio y bechamel casera.';

/// Publicado en la web, con la descripción en italiano y en español.
Recipe lasagne() => const Recipe(
  id: lasagneId,
  nameIt: 'Lasagne alla bolognese',
  nameEs: 'Lasaña a la boloñesa',
  nameEn: 'Lasagne Bolognese',
  descriptionIt: lasagneDescriptionIt,
  descriptionEs: lasagneDescriptionEs,
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

/// Publicado en la web, solo con la descripción en italiano.
Recipe risotto() => const Recipe(
  id: risottoId,
  nameIt: 'Risotto ai funghi porcini',
  nameEs: 'Risotto de hongos porcini',
  nameEn: 'Porcini mushroom risotto',
  descriptionIt: 'Porcini freschi e parmigiano.',
  diet: Diet.vegetarian,
  allergens: [Allergen.milk, Allergen.celery, Allergen.sulphites],
  seasonMonths: [9, 10, 11],
  fridgeDays: 2,
  notes: 'Si può fare senza burro e parmigiano.',
);

/// Activo, pero sin descripción: no sale en la web.
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

/// Desactivado (con descripción: igual no sale en la web).
Recipe frittata() => const Recipe(
  id: frittataId,
  nameIt: 'Frittata di zucchine',
  nameEs: 'Tortilla de zapallitos',
  descriptionIt: 'Zucchine, uova e menta.',
  diet: Diet.vegetarian,
  allergens: [Allergen.eggs, Allergen.milk],
  seasonMonths: [5, 6, 7, 8, 9],
  fridgeDays: 2,
  active: false,
);

/// Tres activos y uno desactivado, desordenados.
List<Recipe> sampleRecipes() => [risotto(), frittata(), lasagne(), minestrone()];

/// Escrito en español (20/11/2026): el italiano y el inglés los llenó la
/// traducción automática, salvo el nombre en italiano, que Evelyn corrigió a
/// mano. No está en [sampleRecipes].
Recipe milanesa() => const Recipe(
  id: milanesaId,
  nameIt: 'Cotoletta alla napoletana',
  nameEs: 'Milanesa a la napolitana',
  nameEn: 'Neapolitan-style milanese',
  descriptionIt: 'Con pomodoro, prosciutto cotto e mozzarella.',
  descriptionEs: 'Con salsa de tomate, jamón y mozzarella.',
  descriptionEn: 'With tomato sauce, ham and mozzarella.',
  autoTranslated: {TranslatedField.descriptionIt, TranslatedField.nameEn, TranslatedField.descriptionEn},
  allergens: [Allergen.gluten, Allergen.eggs, Allergen.milk],
);

/// La descripción de la web de [pastel]: en español, en el campo italiano.
const String pastelDescription = 'Carne picada, puré de papas y queso gratinado.';

/// Un plato viejo (anterior a la traducción, 20/11/2026): sin el nombre en
/// español, porque Evelyn escribió en español en el campo italiano, también
/// la descripción. Sin inglés. No está en [sampleRecipes].
Recipe pastel() => const Recipe(
  id: pastelId,
  nameIt: 'Pastel de papa',
  descriptionIt: pastelDescription,
  allergens: [Allergen.milk],
  freezable: true,
);

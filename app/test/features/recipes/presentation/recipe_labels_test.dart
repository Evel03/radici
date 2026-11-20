// Textos del catálogo en los tres idiomas: secciones del súper, unidades (con
// «q.b.»), el choque de dieta y la temporada con los meses del idioma.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/l10n/app_localizations.dart';

void main() {
  AppLocalizations l10n(String code) => lookupAppLocalizations(Locale(code));

  setUpAll(() async {
    for (final code in ['it', 'es', 'en']) {
      await initializeDateFormatting(code);
    }
  });

  test('cada sección del súper tiene su nombre, en el orden del recorrido', () {
    expect(ShoppingSection.values.map(l10n('it').shoppingSection), [
      'Frutta e verdura',
      'Carne e pesce',
      'Latticini e uova',
      'Panetteria',
      'Dispensa',
      'Surgelati',
      'Altro',
    ]);
    expect(l10n('es').shoppingSection(ShoppingSection.pantry), 'Almacén');
    expect(l10n('en').shoppingSection(ShoppingSection.produce), 'Fruit and veg');
  });

  test('unidades: g, ml, por unidad y «q.b.» en cada idioma', () {
    expect(UnitChoice.values.map(l10n('it').unitChoice), ['g', 'ml', 'pz', 'q.b.']);
    expect(UnitChoice.values.map(l10n('es').unitChoice), ['g', 'ml', 'unid.', 'al gusto']);
    expect(UnitChoice.values.map(l10n('en').unitChoice), ['g', 'ml', 'ea', 'to taste']);
  });

  test('choque de dieta: nombra los alérgenos que sobran, después de dos puntos y separados por «·»', () {
    expect(
      l10n('es').dietConflict(Diet.vegan, const [Allergen.eggs, Allergen.milk]),
      'Un plato vegano no puede llevar: Huevos · Leche y lácteos. Quita la dieta o esos alérgenos.',
    );
    expect(
      l10n('it').dietConflict(Diet.vegetarian, const [Allergen.fish]),
      'Un piatto vegetariano non può contenere: Pesce. Togli la dieta o questi allergeni.',
    );
    expect(
      l10n('en').dietConflict(Diet.vegan, const [Allergen.eggs, Allergen.milk]),
      "A vegan dish can't contain: Eggs · Milk and dairy. Remove the diet or these allergens.",
    );
  });

  test('meses abreviados para los chips y completos para la lectura de pantalla', () {
    final it = RecipeFormats.forLocale('it');
    expect([for (var m = 1; m <= 12; m++) it.monthShort(m)], [
      'gen', 'feb', 'mar', 'apr', 'mag', 'giu', 'lug', 'ago', 'set', 'ott', 'nov', 'dic',
    ]);
    expect(it.monthLong(9), 'settembre');
    expect(RecipeFormats.forLocale('es').monthShort(9), 'sept');
    expect(RecipeFormats.forLocale('en').monthLong(1), 'January');
  });

  test('temporada: tramos con guion y separados por coma', () {
    final it = RecipeFormats.forLocale('it');
    expect(it.season(const [9, 10, 11]), 'set–nov');
    expect(it.season(const [1, 2, 3, 4, 10, 11, 12]), 'ott–apr');
    expect(it.season(const [1, 2, 6, 11, 12]), 'giu, nov–feb');
    expect(it.season(const [7]), 'lug');
    expect(it.season(const [9, 10, 11], long: true), 'settembre–novembre');
    expect(RecipeFormats.forLocale('es').season(const [5, 6, 7, 8, 9]), 'may–sept');
    expect(RecipeFormats.forLocale('en').season(const [12, 1]), 'Dec–Jan');
  });
}

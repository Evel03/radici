// Las cantidades de la lista en el idioma de la interfaz (1250 g como
// 1,25 kg), cuántos platos y renglones tiene un menú y por qué choca un plato.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/features/week_menu/presentation/week_menu_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

void main() {
  final es = lookupAppLocalizations(const Locale('es'));
  final it = lookupAppLocalizations(const Locale('it'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('las cantidades: g y ml hasta 999, después kg y l con los decimales del idioma', () {
    final formats = ShoppingFormats.forLocale(es, 'es');
    expect(formats.amount((quantity: 300, unit: IngredientUnit.g)), '300 g');
    expect(formats.amount((quantity: 999, unit: IngredientUnit.ml)), '999 ml');
    expect(formats.amount((quantity: 1000, unit: IngredientUnit.g)), '1 kg');
    expect(formats.amount((quantity: 1250, unit: IngredientUnit.g)), '1,25 kg');
    expect(
      formats.amount((quantity: 1255, unit: IngredientUnit.g)),
      '1,255 kg',
    );
    expect(formats.amount((quantity: 2100, unit: IngredientUnit.ml)), '2,1 l');
    expect(formats.amount((quantity: 3, unit: IngredientUnit.pcs)), '3 unid.');
    expect(formats.amount(null), 'al gusto');
    expect(
      ShoppingFormats.forLocale(
        it,
        'it',
      ).amount((quantity: 3, unit: IngredientUnit.pcs)),
      '3 pz',
    );
    expect(ShoppingFormats.forLocale(it, 'it').amount(null), 'q.b.');
    expect(
      ShoppingFormats.forLocale(
        en,
        'en',
      ).amount((quantity: 1250, unit: IngredientUnit.g)),
      '1.25 kg',
    );
  });

  test('cuántos platos y renglones', () {
    expect(
      es.weekMenuSummaryText(
        const WeekMenuSummary(saved: true, dishes: 4, items: 23),
      ),
      '4 platos · 23 en la lista de compras',
    );
    expect(
      es.weekMenuSummaryText(
        const WeekMenuSummary(saved: true, dishes: 1, items: 0),
      ),
      '1 plato · lista de compras vacía',
    );
    expect(
      it.weekMenuSummaryText(
        const WeekMenuSummary(saved: true, dishes: 2, items: 1),
      ),
      '2 piatti · 1 voce nella lista della spesa',
    );
  });

  test('por qué choca un plato: los alérgenos y después las dietas', () {
    expect(
      es.dishConflictText(
        const DishConflict(
          allergens: [Allergen.gluten, Allergen.milk],
          diets: [Diet.vegetarian],
        ),
      ),
      'Lleva: Gluten · Leche y lácteos · No está marcado como vegetariano',
    );
    expect(
      en.dishConflictText(const DishConflict(diets: [Diet.vegan])),
      'Not marked vegan',
    );
  });
}

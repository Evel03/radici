// Textos del menú de una semana: cuántos platos y renglones tiene, por qué un
// plato choca con la reserva y las cantidades de la lista (1250 g como
// 1,25 kg, con los decimales del idioma). Solo presentación: los textos salen
// del ARB.
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Desde cuántos gramos o mililitros la lista los muestra en kilos o litros.
const int _bigUnit = 1000;

extension WeekMenuLabels on AppLocalizations {
  /// «4 platos · 23 en la lista de compras».
  String weekMenuSummaryText(WeekMenuSummary summary) =>
      '${weekMenuDishCount(summary.dishes)} · ${weekMenuItemCount(summary.items)}';

  /// Por qué choca un plato: «Lleva: Gluten · Leche y lácteos · No está
  /// marcado como vegetariano».
  String dishConflictText(DishConflict conflict) => [
    if (conflict.allergens.isNotEmpty)
      weekMenuConflictAllergens(
        allergenList(conflict.allergens, separator: ' · '),
      ),
    for (final diet in conflict.diets)
      switch (diet) {
        Diet.vegetarian => weekMenuNotVegetarian,
        Diet.vegan => weekMenuNotVegan,
      },
  ].join(' · ');
}

/// Las cantidades de la lista en el idioma de la interfaz.
class ShoppingFormats {
  ShoppingFormats(BuildContext context)
    : this.forLocale(
        AppLocalizations.of(context),
        Localizations.localeOf(context).toLanguageTag(),
      );

  ShoppingFormats.forLocale(this._l10n, String locale)
    : _number = NumberFormat.decimalPattern(locale);

  final AppLocalizations _l10n;
  final NumberFormat _number;

  /// «300 g», «1,25 kg», «1,5 l», «3 unid.» o «al gusto».
  String amount(IngredientAmount? amount) {
    if (amount == null) return _l10n.recipeUnitToTaste;
    final quantity = amount.quantity;
    final (num value, String unit) = switch (amount.unit) {
      IngredientUnit.g when quantity >= _bigUnit => (
        quantity / _bigUnit,
        _l10n.shoppingUnitKilograms,
      ),
      IngredientUnit.ml when quantity >= _bigUnit => (
        quantity / _bigUnit,
        _l10n.shoppingUnitLiters,
      ),
      IngredientUnit.g => (quantity, _l10n.recipeUnitGrams),
      IngredientUnit.ml => (quantity, _l10n.recipeUnitMilliliters),
      IngredientUnit.pcs => (quantity, _l10n.recipeUnitPieces),
    };
    return _l10n.shoppingAmount(_number.format(value), unit);
  }
}

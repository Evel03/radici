// Textos del catálogo de platos: secciones del súper, unidades, el choque de
// dieta, y los meses y la temporada en el idioma de la interfaz. Solo
// presentación: los textos salen del ARB y los nombres de los meses, de los
// datos de idioma de intl (como el mes de la agenda).
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

extension RecipeLabels on AppLocalizations {
  String shoppingSection(ShoppingSection section) => switch (section) {
    ShoppingSection.produce => shoppingSectionProduce,
    ShoppingSection.meatFish => shoppingSectionMeatFish,
    ShoppingSection.dairyEggs => shoppingSectionDairyEggs,
    ShoppingSection.bakery => shoppingSectionBakery,
    ShoppingSection.pantry => shoppingSectionPantry,
    ShoppingSection.frozen => shoppingSectionFrozen,
    ShoppingSection.other => shoppingSectionOther,
  };

  String unitChoice(UnitChoice unit) => switch (unit) {
    UnitChoice.g => recipeUnitGrams,
    UnitChoice.ml => recipeUnitMilliliters,
    UnitChoice.pcs => recipeUnitPieces,
    UnitChoice.toTaste => recipeUnitToTaste,
  };

  /// "Glutine, Latte e derivati".
  String allergenList(Iterable<Allergen> allergens, {String separator = ', '}) =>
      allergens.map(allergen).join(separator);

  /// Por qué [diet] no va con [allergens] (los que sobran): los nombres de los
  /// chips van después de dos puntos, separados como en la lista de platos.
  String dietConflict(Diet diet, List<Allergen> allergens) {
    final list = allergenList(allergens, separator: ' · ');
    return switch (diet) {
      Diet.vegan => recipeDietConflictVegan(list),
      Diet.vegetarian => recipeDietConflictVegetarian(list),
    };
  }
}

/// Meses y temporada en el idioma de la interfaz.
class RecipeFormats {
  RecipeFormats(BuildContext context)
    : this.forLocale(Localizations.localeOf(context).toLanguageTag());

  RecipeFormats.forLocale(this._locale);

  final String _locale;

  /// "set" (para los chips).
  String monthShort(int month) =>
      DateFormat.LLL(_locale).format(DateTime(2026, month));

  /// "settembre" (para la lectura de pantalla).
  String monthLong(int month) =>
      DateFormat.LLLL(_locale).format(DateTime(2026, month));

  /// "set–nov" o "giu, nov–feb" (con [long], los meses completos). [months]
  /// no puede ser «todo el año» (null).
  String season(List<int> months, {bool long = false}) {
    final name = long ? monthLong : monthShort;
    return [
      for (final range in seasonRanges(months))
        range.first == range.last
            ? name(range.first)
            : '${name(range.first)}–${name(range.last)}',
    ].join(', ');
  }
}

// Formulario de un plato: lo que la cocinera escribe, tal cual (los números
// como texto), y su validación, con las mismas reglas que los checks de la
// base más la dieta contra los alérgenos. Dart puro.
//
// De acá sale el plato que se guarda con save_recipe (recipeFromDraft). Las
// notas son de la cocinera: el borrador no las imprime en toString.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

part 'recipe_draft.freezed.dart';

/// Lo que se elige en la unidad de un ingrediente: g, ml, piezas o «q.b.»
/// (sin cantidad).
enum UnitChoice {
  g,
  ml,
  pcs,
  toTaste;

  /// La unidad de la base; null en «q.b.».
  IngredientUnit? get unit => switch (this) {
    UnitChoice.g => IngredientUnit.g,
    UnitChoice.ml => IngredientUnit.ml,
    UnitChoice.pcs => IngredientUnit.pcs,
    UnitChoice.toTaste => null,
  };

  static UnitChoice of(IngredientAmount? amount) => switch (amount?.unit) {
    null => UnitChoice.toTaste,
    IngredientUnit.g => UnitChoice.g,
    IngredientUnit.ml => UnitChoice.ml,
    IngredientUnit.pcs => UnitChoice.pcs,
  };
}

/// Una fila de ingrediente del formulario.
@Freezed(fromJson: false, toJson: false)
abstract class IngredientDraft with _$IngredientDraft {
  const factory IngredientDraft({
    /// Identifica la fila mientras se edita: sus campos la siguen al
    /// reordenar.
    required int key,
    @Default('') String name,

    /// Para [recipeBasePortions] porciones; se ignora en «q.b.».
    @Default('') String quantity,
    @Default(UnitChoice.g) UnitChoice unit,
    @Default(ShoppingSection.other) ShoppingSection section,
  }) = _IngredientDraft;

  const IngredientDraft._();

  /// Sin nombre ni cantidad: no cuenta (no se valida ni se guarda).
  bool get isBlank =>
      normalizeRecipeText(name).isEmpty && quantity.trim().isEmpty;
}

/// El formulario de un plato.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class RecipeDraft with _$RecipeDraft {
  const factory RecipeDraft({
    required String id,
    @Default('') String nameIt,
    @Default('') String nameEs,
    @Default('') String nameEn,
    @Default(<Allergen>{}) Set<Allergen> allergens,
    Diet? diet,

    /// Vacío = todo el año.
    @Default(<int>{}) Set<int> months,
    @Default('$defaultFridgeDays') String fridgeDays,
    @Default(false) bool freezable,
    @Default('$defaultFreezerDays') String freezerDays,

    /// De la cocinera: nunca se loguean.
    @Default('') String notes,
    @Default(<IngredientDraft>[]) List<IngredientDraft> ingredients,
  }) = _RecipeDraft;

  const RecipeDraft._();

  @override
  String toString() => 'RecipeDraft($id)';
}

/// Un plato nuevo, con el id que generó el teléfono.
RecipeDraft emptyRecipeDraft(String id) => RecipeDraft(id: id);

/// El formulario de [recipe]; con [id], el de una copia (duplicar es guardar
/// el mismo plato con un id nuevo). Las filas llevan las claves 0, 1, 2…
RecipeDraft recipeDraftFrom(Recipe recipe, {String? id}) => RecipeDraft(
  id: id ?? recipe.id,
  nameIt: recipe.nameIt,
  nameEs: recipe.nameEs ?? '',
  nameEn: recipe.nameEn ?? '',
  allergens: recipe.allergens.toSet(),
  diet: recipe.diet,
  months: {...?recipe.seasonMonths},
  fridgeDays: '${recipe.fridgeDays}',
  freezable: recipe.freezable,
  freezerDays: '${recipe.freezerDays}',
  notes: recipe.notes ?? '',
  ingredients: [
    for (final (index, ingredient) in recipe.ingredients.indexed)
      IngredientDraft(
        key: index,
        name: ingredient.name,
        quantity: ingredient.amount == null ? '' : '${ingredient.amount!.quantity}',
        unit: UnitChoice.of(ingredient.amount),
        section: ingredient.section,
      ),
  ],
);

/// Error de un texto: falta o es demasiado largo.
enum TextError { required, tooLong }

/// Error de la cantidad de un ingrediente.
enum QuantityError { required, outOfRange }

final class IngredientDraftErrors {
  const IngredientDraftErrors({this.name, this.quantity});

  final TextError? name;
  final QuantityError? quantity;
}

/// Los errores del formulario; [isEmpty] = se puede guardar.
final class RecipeDraftErrors {
  const RecipeDraftErrors({
    this.nameIt,
    this.nameEs,
    this.nameEn,
    this.notes,
    this.dietConflicts = const [],
    this.fridgeDays = false,
    this.freezerDays = false,
    this.ingredients = const {},
    this.tooManyIngredients = false,
  });

  final TextError? nameIt;
  final TextError? nameEs;
  final TextError? nameEn;
  final TextError? notes;

  /// Los alérgenos marcados que la dieta elegida no admite.
  final List<Allergen> dietConflicts;

  /// true = el número de días no vale.
  final bool fridgeDays;
  final bool freezerDays;

  /// Por la clave de la fila; solo las filas con algún error.
  final Map<int, IngredientDraftErrors> ingredients;
  final bool tooManyIngredients;

  bool get isEmpty =>
      nameIt == null &&
      nameEs == null &&
      nameEn == null &&
      notes == null &&
      dietConflicts.isEmpty &&
      !fridgeDays &&
      !freezerDays &&
      ingredients.isEmpty &&
      !tooManyIngredients;
}

TextError? _nameError(String raw, int max, {bool required = false}) {
  final clean = normalizeRecipeText(raw);
  if (clean.isEmpty) return required ? TextError.required : null;
  return textLength(clean) > max ? TextError.tooLong : null;
}

/// [raw] como número de días entre [min] y [max], o null si no vale.
int? _days(String raw, int min, int max) {
  final value = int.tryParse(raw.trim());
  return value == null || value < min || value > max ? null : value;
}

/// [raw] como cantidad válida, o null.
int? _quantity(String raw) {
  final value = int.tryParse(raw.trim());
  return value == null || value < 1 || value > maxIngredientQuantity ? null : value;
}

/// Valida [draft] con las reglas de la base (nombres, cantidades, hasta 50
/// ingredientes), los topes de conservación del formulario y la dieta contra
/// los alérgenos.
RecipeDraftErrors validateRecipeDraft(RecipeDraft draft) {
  final rows = [
    for (final row in draft.ingredients)
      if (!row.isBlank) row,
  ];
  final ingredientErrors = <int, IngredientDraftErrors>{};
  for (final row in rows) {
    final name = _nameError(row.name, maxIngredientNameLength, required: true);
    QuantityError? quantity;
    if (row.unit != UnitChoice.toTaste) {
      if (row.quantity.trim().isEmpty) {
        quantity = QuantityError.required;
      } else if (_quantity(row.quantity) == null) {
        quantity = QuantityError.outOfRange;
      }
    }
    if (name != null || quantity != null) {
      ingredientErrors[row.key] = IngredientDraftErrors(name: name, quantity: quantity);
    }
  }
  final notes = draft.notes.trim();
  return RecipeDraftErrors(
    nameIt: _nameError(draft.nameIt, maxRecipeNameLength, required: true),
    nameEs: _nameError(draft.nameEs, maxRecipeNameLength),
    nameEn: _nameError(draft.nameEn, maxRecipeNameLength),
    notes: textLength(notes) > maxRecipeNotesLength ? TextError.tooLong : null,
    dietConflicts: dietConflicts(draft.diet, draft.allergens),
    fridgeDays: _days(draft.fridgeDays, 0, maxFridgeDays) == null,
    freezerDays: draft.freezable && _days(draft.freezerDays, 1, maxFreezerDays) == null,
    ingredients: ingredientErrors,
    tooManyIngredients: rows.length > maxIngredients,
  );
}

/// El plato que sale de [draft], listo para save_recipe: nombres limpios,
/// traducciones y notas vacías en null, los 12 meses como todo el año y sin
/// las filas vacías. [saved] es el plato guardado (null si es nuevo): de él
/// salen el estado (guardar no lo cambia) y, si no se puede congelar y el
/// número de días del freezer no vale, esos días. Lanza [ArgumentError] si
/// [draft] tiene errores.
Recipe recipeFromDraft(RecipeDraft draft, {Recipe? saved}) {
  if (!validateRecipeDraft(draft).isEmpty) {
    throw ArgumentError.value(draft, 'draft', 'El formulario tiene errores');
  }
  String? optional(String raw) {
    final clean = normalizeRecipeText(raw);
    return clean.isEmpty ? null : clean;
  }

  final notes = draft.notes.trim();
  return Recipe(
    id: draft.id,
    nameIt: normalizeRecipeText(draft.nameIt),
    nameEs: optional(draft.nameEs),
    nameEn: optional(draft.nameEn),
    diet: draft.diet,
    allergens: [
      for (final allergen in Allergen.values)
        if (draft.allergens.contains(allergen)) allergen,
    ],
    seasonMonths: normalizeSeasonMonths(draft.months),
    fridgeDays: _days(draft.fridgeDays, 0, maxFridgeDays)!,
    freezable: draft.freezable,
    freezerDays:
        _days(draft.freezerDays, 1, maxFreezerDays) ??
        saved?.freezerDays ??
        defaultFreezerDays,
    notes: notes.isEmpty ? null : notes,
    active: saved?.active ?? true,
    ingredients: [
      for (final row in draft.ingredients)
        if (!row.isBlank)
          RecipeIngredient(
            name: normalizeRecipeText(row.name),
            section: row.section,
            amount: switch (row.unit.unit) {
              null => null,
              final unit => (quantity: _quantity(row.quantity)!, unit: unit),
            },
          ),
    ],
  );
}

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

    /// La descripción corta de la web, en los tres idiomas.
    @Default('') String descriptionIt,
    @Default('') String descriptionEs,
    @Default('') String descriptionEn,

    /// Los campos que llenó la traducción automática y la cocinera no tocó a
    /// mano ([Recipe.autoTranslated]).
    @Default(<TranslatedField>{}) Set<TranslatedField> autoTranslated,
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

  /// Lo escrito en [field].
  String textOf(TranslatedField field) => switch (field) {
    TranslatedField.nameIt => nameIt,
    TranslatedField.descriptionIt => descriptionIt,
    TranslatedField.nameEn => nameEn,
    TranslatedField.descriptionEn => descriptionEn,
  };

  /// El español del que sale [field]: el nombre o la descripción.
  String sourceOf(TranslatedField field) =>
      field.isName ? nameEs : descriptionEs;

  /// El formulario con [text] en [field] (las marcas no cambian).
  RecipeDraft withText(TranslatedField field, String text) => switch (field) {
    TranslatedField.nameIt => copyWith(nameIt: text),
    TranslatedField.descriptionIt => copyWith(descriptionIt: text),
    TranslatedField.nameEn => copyWith(nameEn: text),
    TranslatedField.descriptionEn => copyWith(descriptionEn: text),
  };

  @override
  String toString() => 'RecipeDraft($id)';
}

/// Un plato nuevo, con el id que generó el teléfono.
RecipeDraft emptyRecipeDraft(String id) => RecipeDraft(id: id);

/// El formulario de [recipe]; con [id], el de una copia (duplicar es guardar
/// el mismo plato con un id nuevo), sin las descripciones de la web: la copia
/// es otro plato y no tiene que salir en la web con la descripción del
/// original («Senza descrizione: non è sul sito» hasta que tenga la suya).
/// Por eso la copia no lleva las marcas de la traducción automática de las
/// descripciones; las de los nombres, que sí copia, quedan (SPEC §4). Las
/// filas llevan las claves 0, 1, 2…
RecipeDraft recipeDraftFrom(Recipe recipe, {String? id}) => RecipeDraft(
  id: id ?? recipe.id,
  nameIt: recipe.nameIt,
  nameEs: recipe.nameEs ?? '',
  nameEn: recipe.nameEn ?? '',
  descriptionIt: id == null ? recipe.descriptionIt ?? '' : '',
  descriptionEs: id == null ? recipe.descriptionEs ?? '' : '',
  descriptionEn: id == null ? recipe.descriptionEn ?? '' : '',
  autoTranslated: {
    for (final field in recipe.autoTranslated)
      if (id == null || field.isName) field,
  },
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
    this.descriptionIt,
    this.descriptionEs,
    this.descriptionEn,
    this.notes,
    this.dietConflicts = const [],
    this.fridgeDays = false,
    this.freezerDays = false,
    this.ingredients = const {},
    this.tooManyIngredients = false,
    this.spanishNameToTranslate = false,
  });

  final TextError? nameIt;
  final TextError? nameEs;

  /// El nombre en español falta porque hace falta para traducir la
  /// descripción en español (un plato viejo sin él): [nameEs] es
  /// [TextError.required] y el editor dice por qué.
  final bool spanishNameToTranslate;
  final TextError? nameEn;

  /// Las descripciones son opcionales: solo pueden ser demasiado largas.
  final TextError? descriptionIt;
  final TextError? descriptionEs;
  final TextError? descriptionEn;
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
      descriptionIt == null &&
      descriptionEs == null &&
      descriptionEn == null &&
      notes == null &&
      dietConflicts.isEmpty &&
      !fridgeDays &&
      !freezerDays &&
      ingredients.isEmpty &&
      !tooManyIngredients;
}

TextError? _nameError(String raw, int max, {bool required = false}) {
  final length = recipeTextLength(raw);
  if (length == 0) return required ? TextError.required : null;
  return length > max ? TextError.tooLong : null;
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

/// Valida [draft] con las reglas de la base (nombres, descripciones,
/// cantidades, hasta 50 ingredientes), los topes de conservación del
/// formulario y la dieta contra los alérgenos.
///
/// Las del editor desde que el español es la fuente (20/11/2026): con
/// [requireSpanish], el nombre en español es obligatorio (un plato nuevo, o
/// uno que ya lo tenía); con [willTranslate], el nombre en italiano vacío no
/// falta si sale del español (lo traduce el guardado), y el nombre en español
/// falta si hay que traducir la descripción en español (la italiana o la
/// inglesa vacía o automática): el traductor lo exige. Sin ellas, las de la
/// base: el italiano es obligatorio.
RecipeDraftErrors validateRecipeDraft(
  RecipeDraft draft, {
  bool requireSpanish = false,
  bool willTranslate = false,
}) {
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
  // Sin el español, si es obligatorio, lo que falta es el español: el
  // italiano sale de ahí.
  final italianFromSpanish =
      willTranslate && (requireSpanish || normalizeRecipeText(draft.nameEs).isNotEmpty);
  // Sin el nombre en español no se traduce nada: si hay una descripción en
  // español que traducir, el nombre pasa a hacer falta.
  final spanishNameToTranslate =
      willTranslate &&
      !requireSpanish &&
      normalizeRecipeText(draft.nameEs).isEmpty &&
      normalizeRecipeText(draft.descriptionEs).isNotEmpty &&
      [TranslatedField.descriptionIt, TranslatedField.descriptionEn].any(
        (field) =>
            normalizeRecipeText(draft.textOf(field)).isEmpty ||
            draft.autoTranslated.contains(field),
      );
  return RecipeDraftErrors(
    nameIt: _nameError(draft.nameIt, maxRecipeNameLength, required: !italianFromSpanish),
    nameEs: _nameError(
      draft.nameEs,
      maxRecipeNameLength,
      required: requireSpanish || spanishNameToTranslate,
    ),
    spanishNameToTranslate: spanishNameToTranslate,
    nameEn: _nameError(draft.nameEn, maxRecipeNameLength),
    descriptionIt: _nameError(draft.descriptionIt, maxRecipeDescriptionLength),
    descriptionEs: _nameError(draft.descriptionEs, maxRecipeDescriptionLength),
    descriptionEn: _nameError(draft.descriptionEn, maxRecipeDescriptionLength),
    notes: textLength(notes) > maxRecipeNotesLength ? TextError.tooLong : null,
    dietConflicts: dietConflicts(draft.diet, draft.allergens),
    fridgeDays: _days(draft.fridgeDays, 0, maxFridgeDays) == null,
    freezerDays: draft.freezable && _days(draft.freezerDays, 1, maxFreezerDays) == null,
    ingredients: ingredientErrors,
    tooManyIngredients: rows.length > maxIngredients,
  );
}

/// El plato que sale de [draft], listo para save_recipe: nombres y
/// descripciones limpios, traducciones, descripciones y notas vacías en null,
/// los 12 meses como todo el año, sin las filas vacías y con las marcas de la
/// traducción automática solo en los campos con texto y con el español del
/// que salen (como exige save_recipe). [saved] es el plato guardado (null si es nuevo): de él
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
    descriptionIt: optional(draft.descriptionIt),
    descriptionEs: optional(draft.descriptionEs),
    descriptionEn: optional(draft.descriptionEn),
    autoTranslated: {
      for (final field in draft.autoTranslated)
        if (optional(draft.textOf(field)) != null &&
            optional(draft.sourceOf(field)) != null)
          field,
    },
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

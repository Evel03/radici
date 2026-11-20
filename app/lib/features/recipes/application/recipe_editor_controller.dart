// Editor de un plato: el formulario (RecipeDraft) con sus cambios, el
// guardado entero por save_recipe y desactivar o reactivar.
//
// Un plato nuevo (o una copia) lleva un id generado al abrir el editor: cada
// reintento de guardar manda el mismo, así un guardado que llegó al servidor
// pero cuya respuesta se perdió no duplica el plato. Si falla, el formulario
// queda como estaba.
//
// El español es la fuente (20/11/2026): al guardar, antes de save_recipe, se
// traduce al italiano y al inglés lo que dice el plan
// (planRecipeTranslation: lo vacío y lo automático cuyo español cambió). Si
// el traductor falla no se guarda nada y lo escrito queda; se puede
// reintentar, escribir a mano lo que falta o guardar sin traducir (lo
// automático viejo se vacía: nunca queda una traducción vieja como si fuera
// la del español nuevo).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/domain/recipe_translation.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

part 'recipe_editor_controller.freezed.dart';

/// Qué abre el editor.
@freezed
sealed class RecipeEditorTarget with _$RecipeEditorTarget {
  /// Un plato nuevo, vacío.
  const factory RecipeEditorTarget.create() = CreateRecipe;

  /// Un plato del catálogo.
  const factory RecipeEditorTarget.edit(String id) = EditRecipe;

  /// La copia de un plato del catálogo (duplicar), con un id nuevo.
  const factory RecipeEditorTarget.copy(String sourceId) = CopyRecipe;
}

@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class RecipeEditorState with _$RecipeEditorState {
  const factory RecipeEditorState({
    required RecipeDraft draft,

    /// El formulario como se abrió o como se guardó por última vez.
    required RecipeDraft initial,

    /// El plato que se edita o el que se copia; null en uno nuevo.
    Recipe? source,

    /// Todavía no se guardó (nuevo o copia).
    required bool isNew,

    /// El español del que salen los campos automáticos del formulario: el
    /// guardado al abrir, o el de la última traducción.
    required SpanishText translatedFrom,

    /// Después del primer intento de guardar con errores: se muestran.
    @Default(false) bool showErrors,
    @Default(false) bool saving,

    /// Se está traduciendo antes de guardar (puede tardar).
    @Default(false) bool translating,

    /// Por qué falló el último guardado (null si no falló).
    RecipesFailureKind? saveError,

    /// Por qué falló la última traducción (null si no falló). No se guardó
    /// nada.
    TranslationFailureKind? translateError,

    /// Se está desactivando o reactivando.
    @Default(false) bool changingActive,
  }) = _RecipeEditorState;

  const RecipeEditorState._();

  /// Hay cambios sin guardar.
  bool get dirty => draft != initial;

  /// Traduciendo o guardando: no se puede volver a guardar ni salir.
  bool get busy => saving || translating;

  /// El nombre en español es obligatorio: en un plato nuevo (o una copia) y
  /// en uno que ya lo tenía. Un plato viejo sin español se guarda como está.
  bool get spanishRequired => isNew || source?.nameEs != null;

  /// El nombre en italiano vacío no falta si sale del español: lo traduce el
  /// guardado.
  RecipeDraftErrors get errors => validateRecipeDraft(
    draft,
    requireSpanish: spanishRequired,
    willTranslate: true,
  );

  /// Qué se traduce (o se vacía) al guardar.
  RecipeTranslationPlan get translationPlan =>
      planRecipeTranslation(draft, translatedFrom: translatedFrom);

  @override
  String toString() => 'RecipeEditorState(${draft.id})';
}

/// Resultado de [RecipeEditorController.save].
enum RecipeSaveResult {
  saved,

  /// El formulario tiene errores: no se mandó nada.
  invalid,

  /// El servidor no lo guardó (ver [RecipeEditorState.saveError]).
  failed,

  /// El traductor falló (ver [RecipeEditorState.translateError]): no se
  /// guardó nada y el formulario quedó como estaba.
  translationFailed,

  /// El formulario cambió mientras se traducía (o se cerró el editor): no se
  /// aplicó la traducción ni se guardó nada.
  stale,

  /// Ya se estaba guardando o traduciendo.
  busy,
}

/// Una fila quitada y dónde estaba, para «Deshacer».
typedef RemovedIngredient = ({IngredientDraft row, int index});

/// El editor de [RecipeEditorTarget]. Para editar o copiar, el catálogo tiene
/// que estar cargado y tener el plato (la pantalla lo espera).
final recipeEditorProvider = NotifierProvider.autoDispose
    .family<RecipeEditorController, RecipeEditorState, RecipeEditorTarget>(
      RecipeEditorController.new,
    );

/// Ya hay otro plato con el nombre en italiano del editor (por ejemplo, una
/// copia sin renombrar). Es un aviso: no impide guardar.
final recipeNameTakenProvider = Provider.autoDispose
    .family<bool, RecipeEditorTarget>((ref, target) {
      final (id, name) = ref.watch(
        recipeEditorProvider(
          target,
        ).select((state) => (state.draft.id, state.draft.nameIt)),
      );
      // Uno automático que se va a traducir de nuevo (cambió el español) no
      // avisa: el nombre va a cambiar al guardar.
      final retranslated = ref.watch(
        recipeEditorProvider(target).select(
          (state) => state.translationPlan.translate.contains(TranslatedField.nameIt),
        ),
      );
      if (retranslated) return false;
      final catalog = ref.watch(recipeCatalogProvider).value ?? const [];
      return hasRecipeNamed(catalog, name, exceptId: id);
    });

/// El plato [id] tal como está en el catálogo (null si no está o mientras
/// carga). El editor muestra de acá si está activo.
final recipeByIdProvider = Provider.autoDispose.family<Recipe?, String>((
  ref,
  id,
) {
  final catalog = ref.watch(recipeCatalogProvider).value ?? const [];
  return catalog.where((recipe) => recipe.id == id).firstOrNull;
});

class RecipeEditorController extends Notifier<RecipeEditorState> {
  RecipeEditorController(this.target);

  final RecipeEditorTarget target;

  /// Clave de la próxima fila de ingrediente.
  int _nextKey = 0;

  @override
  RecipeEditorState build() {
    // Se lee una vez: el formulario no se rearma si el catálogo cambia
    // mientras se edita (por ejemplo, al guardar).
    final catalog = ref.read(recipeCatalogProvider).value ?? const <Recipe>[];
    Recipe find(String id) => catalog.firstWhere(
      (recipe) => recipe.id == id,
      orElse: () => throw StateError('El plato no está en el catálogo'),
    );
    final (draft, source, isNew) = switch (target) {
      CreateRecipe() => (emptyRecipeDraft(ref.read(newIdProvider)()), null, true),
      EditRecipe(:final id) => (recipeDraftFrom(find(id)), find(id), false),
      CopyRecipe(:final sourceId) => (
        recipeDraftFrom(find(sourceId), id: ref.read(newIdProvider)()),
        find(sourceId),
        true,
      ),
    };
    _nextKey = draft.ingredients.length;
    return RecipeEditorState(
      draft: draft,
      initial: draft,
      source: source,
      isNew: isNew,
      // Los campos automáticos de un plato guardado salen de su español.
      translatedFrom: spanishTextOf(draft),
    );
  }

  void _edit(RecipeDraft Function(RecipeDraft draft) change) =>
      state = state.copyWith(draft: change(state.draft));

  /// Escribir a mano en un campo de destino lo saca de los automáticos: no se
  /// vuelve a traducir encima.
  void _editTranslation(TranslatedField field, String value) => _edit(
    (d) => d
        .withText(field, value)
        .copyWith(autoTranslated: d.autoTranslated.difference({field})),
  );

  void setNameIt(String value) => _editTranslation(TranslatedField.nameIt, value);

  void setNameEs(String value) => _edit((d) => d.copyWith(nameEs: value));

  void setNameEn(String value) => _editTranslation(TranslatedField.nameEn, value);

  void setDescriptionIt(String value) =>
      _editTranslation(TranslatedField.descriptionIt, value);

  void setDescriptionEs(String value) =>
      _edit((d) => d.copyWith(descriptionEs: value));

  void setDescriptionEn(String value) =>
      _editTranslation(TranslatedField.descriptionEn, value);

  void setNotes(String value) => _edit((d) => d.copyWith(notes: value));

  void toggleAllergen(Allergen allergen) => _edit(
    (d) => d.copyWith(
      allergens: d.allergens.contains(allergen)
          ? d.allergens.difference({allergen})
          : {...d.allergens, allergen},
    ),
  );

  void setDiet(Diet? diet) => _edit((d) => d.copyWith(diet: diet));

  /// Marca o desmarca [month]. Con los 12 marcados queda «todo el año».
  void toggleMonth(int month) => _edit((d) {
    final months = d.months.contains(month)
        ? d.months.difference({month})
        : {...d.months, month};
    return d.copyWith(months: months.length == 12 ? const {} : months);
  });

  void setAllYear() => _edit((d) => d.copyWith(months: const {}));

  void setFridgeDays(String value) => _edit((d) => d.copyWith(fridgeDays: value));

  void setFreezable(bool value) => _edit((d) => d.copyWith(freezable: value));

  void setFreezerDays(String value) =>
      _edit((d) => d.copyWith(freezerDays: value));

  /// Agrega una fila vacía al final, en gramos y con la sección de la de
  /// arriba (los ingredientes suelen ir agrupados). Devuelve su clave, o null
  /// si ya hay [maxIngredients].
  int? addIngredient() {
    final rows = state.draft.ingredients;
    if (rows.length >= maxIngredients) return null;
    final key = _nextKey++;
    _edit(
      (d) => d.copyWith(
        ingredients: [
          ...rows,
          IngredientDraft(
            key: key,
            section: rows.isEmpty ? ShoppingSection.other : rows.last.section,
          ),
        ],
      ),
    );
    return key;
  }

  void updateIngredient(
    int key, {
    String? name,
    String? quantity,
    UnitChoice? unit,
    ShoppingSection? section,
  }) => _edit(
    (d) => d.copyWith(
      ingredients: [
        for (final row in d.ingredients)
          if (row.key == key)
            row.copyWith(
              name: name ?? row.name,
              quantity: quantity ?? row.quantity,
              unit: unit ?? row.unit,
              section: section ?? row.section,
            )
          else
            row,
      ],
    ),
  );

  /// Mueve la fila [key] [offset] lugares (-1 sube, 1 baja). En los bordes no
  /// hace nada.
  void moveIngredient(int key, int offset) {
    final rows = [...state.draft.ingredients];
    final from = rows.indexWhere((row) => row.key == key);
    final to = from + offset;
    if (from < 0 || to < 0 || to >= rows.length) return;
    rows.insert(to, rows.removeAt(from));
    _edit((d) => d.copyWith(ingredients: rows));
  }

  /// Quita la fila [key]. Devuelve la fila y su lugar (para
  /// [restoreIngredient]), o null si no estaba.
  RemovedIngredient? removeIngredient(int key) {
    final rows = [...state.draft.ingredients];
    final index = rows.indexWhere((row) => row.key == key);
    if (index < 0) return null;
    final row = rows.removeAt(index);
    _edit((d) => d.copyWith(ingredients: rows));
    return (row: row, index: index);
  }

  /// «Deshacer» de [removeIngredient]: la fila vuelve a su lugar.
  void restoreIngredient(RemovedIngredient removed) {
    final rows = [...state.draft.ingredients];
    if (rows.any((row) => row.key == removed.row.key)) return;
    rows.insert(removed.index.clamp(0, rows.length), removed.row);
    _edit((d) => d.copyWith(ingredients: rows));
  }

  /// Valida, traduce lo que diga el plan y guarda el plato entero. Con
  /// errores no manda nada y los muestra. Si el traductor falla, no guarda
  /// nada y el formulario queda como estaba ([RecipeSaveResult.translationFailed]).
  /// Si el servidor falla al guardar, el formulario queda (con la traducción,
  /// que no se vuelve a pedir) y el próximo intento manda el mismo id.
  Future<RecipeSaveResult> save() async {
    if (state.busy) return RecipeSaveResult.busy;
    if (!_validate()) return RecipeSaveResult.invalid;
    final plan = state.translationPlan;
    // Sin nada que traducir puede haber descripciones automáticas que vaciar
    // (se borró la española).
    if (!plan.needsTranslation) return _persist(plan.skipped);
    state = state.copyWith(
      translating: true,
      saveError: null,
      translateError: null,
    );
    final RecipeTranslation translation;
    try {
      translation = await ref
          .read(translationRepositoryProvider)
          .translate(plan.source);
    } on TranslationFailure catch (failure) {
      if (ref.mounted) {
        state = state.copyWith(translating: false, translateError: failure.kind);
      }
      return RecipeSaveResult.translationFailed;
    }
    if (!ref.mounted) return RecipeSaveResult.stale;
    state = state.copyWith(translating: false);
    // La pantalla no deja escribir mientras traduce; si igual cambió algo, la
    // traducción no lo pisa.
    if (state.draft != plan.draft) return RecipeSaveResult.stale;
    return _persist(plan.translated(translation));
  }

  /// Guarda sin traducir, después de una traducción que falló: lo
  /// automático que había que traducir de nuevo queda vacío (nunca una
  /// traducción vieja como si fuera la del español nuevo), lo vacío queda
  /// vacío y lo escrito a mano, como estaba. Sin el nombre en italiano no se
  /// puede ([RecipeTranslationPlan.canSkip]): no manda nada.
  Future<RecipeSaveResult> saveWithoutTranslating() async {
    if (state.busy) return RecipeSaveResult.busy;
    if (!_validate()) return RecipeSaveResult.invalid;
    final plan = state.translationPlan;
    if (!plan.canSkip) return RecipeSaveResult.invalid;
    return _persist(plan.skipped);
  }

  /// Sin errores; si hay, los muestra.
  bool _validate() {
    if (state.errors.isEmpty) return true;
    state = state.copyWith(
      showErrors: true,
      saveError: null,
      translateError: null,
    );
    return false;
  }

  /// Guarda [draft] (ya traducido o sin traducir) con save_recipe. El
  /// formulario pasa a [draft]: sus campos automáticos salen del español de
  /// [draft], se guarde o no.
  Future<RecipeSaveResult> _persist(RecipeDraft draft) async {
    final recipe = recipeFromDraft(
      draft,
      saved: state.isNew ? null : state.source,
    );
    state = state.copyWith(
      draft: draft,
      translatedFrom: spanishTextOf(draft),
      saving: true,
      saveError: null,
      translateError: null,
    );
    try {
      final saved = await ref.read(recipeCatalogProvider.notifier).save(recipe);
      if (ref.mounted) {
        state = state.copyWith(
          saving: false,
          initial: draft,
          source: saved,
          isNew: false,
        );
      }
      return RecipeSaveResult.saved;
    } on RecipesFailure catch (failure) {
      if (ref.mounted) {
        state = state.copyWith(saving: false, saveError: failure.kind);
      }
      return RecipeSaveResult.failed;
    }
  }

  /// Desactiva o reactiva el plato (solo uno guardado). No toca el
  /// formulario. Si falla, se relanza [RecipesFailure].
  Future<void> setActive({required bool active}) async {
    if (state.isNew || state.changingActive) return;
    state = state.copyWith(changingActive: true);
    try {
      await ref
          .read(recipeCatalogProvider.notifier)
          .setActive(state.draft.id, active: active);
    } finally {
      if (ref.mounted) state = state.copyWith(changingActive: false);
    }
  }
}

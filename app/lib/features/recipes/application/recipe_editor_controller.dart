// Editor de un plato: el formulario (RecipeDraft) con sus cambios, el
// guardado entero por save_recipe, la foto y desactivar o reactivar.
//
// Un plato nuevo (o una copia) lleva un id generado al abrir el editor: cada
// reintento de guardar manda el mismo, así un guardado que llegó al servidor
// pero cuya respuesta se perdió no duplica el plato. Si falla, el formulario
// queda como estaba.
//
// La foto se elige en el mismo editor, también en un plato nuevo: queda
// preparada (achicada y sin metadatos) y se sube al guardar, después del
// plato (los archivos van en la carpeta del plato y set_recipe_photo exige que
// exista). Si la foto falla, el plato queda guardado y la foto sigue en el
// editor para reintentar, con el mismo uuid.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/application/recipe_photo_providers.dart';
import 'package:radici/features/recipes/data/recipe_photo_picker.dart';
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';
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

    /// Después del primer intento de guardar con errores: se muestran.
    @Default(false) bool showErrors,
    @Default(false) bool saving,

    /// Por qué falló el último guardado (null si no falló).
    RecipesFailureKind? saveError,

    /// Se está desactivando o reactivando.
    @Default(false) bool changingActive,

    /// La foto que tiene guardada el plato (null = sin foto; también en uno
    /// nuevo y en una copia: duplicar no copia la foto).
    String? savedPhotoId,

    /// Lo que se cambia en la foto al guardar (null = nada).
    RecipePhotoChange? photoChange,

    /// Se está preparando la foto elegida (achicar, sacar metadatos).
    @Default(false) bool preparingPhoto,

    /// Se está subiendo la foto (mientras guarda, después del plato).
    @Default(false) bool uploadingPhoto,

    /// Por qué falló la foto en el último guardado (el plato sí se guardó);
    /// null si no falló.
    RecipePhotoFailureKind? photoError,
  }) = _RecipeEditorState;

  const RecipeEditorState._();

  /// Hay cambios sin guardar (en el formulario o en la foto).
  bool get dirty => draft != initial || photoChange != null;

  /// La foto elegida que todavía no se subió (null si no hay).
  NewRecipePhoto? get newPhoto => switch (photoChange) {
    ReplaceRecipePhoto(:final photo) => photo,
    _ => null,
  };

  /// La foto guardada que se ve en el editor: null si no tiene, si se eligió
  /// otra o si se va a sacar.
  String? get shownSavedPhotoId => photoChange == null ? savedPhotoId : null;

  RecipeDraftErrors get errors => validateRecipeDraft(draft);

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

  /// El plato se guardó, pero la foto no (ver
  /// [RecipeEditorState.photoError]): sigue en el editor para reintentar.
  photoFailed,

  /// Ya se estaba guardando.
  busy,
}

/// Una fila quitada y dónde estaba, para «Deshacer».
typedef RemovedIngredient = ({IngredientDraft row, int index});

/// Por qué no quedó la foto elegida en [RecipeEditorController.pickPhoto].
enum RecipePhotoPickError {
  /// No es una foto que la app pueda abrir.
  unreadable,

  /// El teléfono no le da permiso a la app (la cámara).
  permissionDenied,

  /// El selector no se pudo abrir.
  unavailable,
}

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
      savedPhotoId: isNew ? null : source?.photoId,
    );
  }

  void _edit(RecipeDraft Function(RecipeDraft draft) change) =>
      state = state.copyWith(draft: change(state.draft));

  void setNameIt(String value) => _edit((d) => d.copyWith(nameIt: value));

  void setNameEs(String value) => _edit((d) => d.copyWith(nameEs: value));

  void setNameEn(String value) => _edit((d) => d.copyWith(nameEn: value));

  void setDescriptionIt(String value) =>
      _edit((d) => d.copyWith(descriptionIt: value));

  void setDescriptionEs(String value) =>
      _edit((d) => d.copyWith(descriptionEs: value));

  void setDescriptionEn(String value) =>
      _edit((d) => d.copyWith(descriptionEn: value));

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

  /// Valida y guarda el plato entero y, si cambió, la foto. Con errores no
  /// manda nada y los muestra. Si el servidor falla, el formulario queda como
  /// estaba y el próximo intento manda el mismo id. Si solo cambió la foto de
  /// un plato ya guardado (por ejemplo, el reintento después de que falló la
  /// foto), no vuelve a mandar el plato.
  Future<RecipeSaveResult> save() async {
    if (state.saving || state.preparingPhoto) return RecipeSaveResult.busy;
    if (!state.errors.isEmpty) {
      state = state.copyWith(showErrors: true, saveError: null);
      return RecipeSaveResult.invalid;
    }
    final draft = state.draft;
    final photoChange = state.photoChange;
    final recipeChanged =
        state.isNew || draft != state.initial || photoChange == null;
    state = state.copyWith(saving: true, saveError: null, photoError: null);
    if (recipeChanged) {
      final recipe = recipeFromDraft(
        draft,
        saved: state.isNew ? null : state.source,
      );
      try {
        final saved = await ref.read(recipeCatalogProvider.notifier).save(recipe);
        if (ref.mounted) {
          state = state.copyWith(
            saving: photoChange != null,
            initial: draft,
            source: saved,
            isNew: false,
          );
        }
      } on RecipesFailure catch (failure) {
        if (ref.mounted) {
          state = state.copyWith(saving: false, saveError: failure.kind);
        }
        return RecipeSaveResult.failed;
      }
    }
    if (photoChange == null || !ref.mounted) return RecipeSaveResult.saved;
    return _savePhoto(draft.id, photoChange);
  }

  Future<RecipeSaveResult> _savePhoto(
    String recipeId,
    RecipePhotoChange change,
  ) async {
    final photo = switch (change) {
      ReplaceRecipePhoto(:final photo) => photo,
      RemoveRecipePhoto() => null,
    };
    state = state.copyWith(uploadingPhoto: true);
    try {
      await ref.read(recipeCatalogProvider.notifier).setPhoto(recipeId, photo);
      if (ref.mounted) {
        state = state.copyWith(
          saving: false,
          uploadingPhoto: false,
          photoChange: null,
          savedPhotoId: photo?.photoId,
          source: state.source?.copyWith(photoId: photo?.photoId),
        );
      }
      return RecipeSaveResult.saved;
    } on RecipePhotoFailure catch (failure) {
      if (ref.mounted) {
        state = state.copyWith(
          saving: false,
          uploadingPhoto: false,
          photoError: failure.kind,
        );
      }
      return RecipeSaveResult.photoFailed;
    }
  }

  /// Abre el selector en [source] y prepara la foto elegida (derecha,
  /// achicada y sin metadatos), con un uuid nuevo: se sube al guardar, en
  /// lugar de la que tenga. Devuelve por qué no quedó (null si quedó o si se
  /// canceló).
  Future<RecipePhotoPickError?> pickPhoto(RecipePhotoSource source) async {
    // Sin una marca de «selector abierto»: en un navegador sin el evento
    // cancel, el selector de la web nunca termina si se cancela, y la marca
    // dejaría el botón sin hacer nada. El selector tapa la pantalla mientras
    // está abierto.
    if (state.saving || state.preparingPhoto) return null;
    final Uint8List? bytes;
    try {
      bytes = await ref.read(recipePhotoPickerProvider).pick(source);
    } on RecipePhotoPickFailure catch (failure) {
      return switch (failure.kind) {
        RecipePhotoPickFailureKind.permissionDenied =>
          RecipePhotoPickError.permissionDenied,
        RecipePhotoPickFailureKind.unavailable =>
          RecipePhotoPickError.unavailable,
      };
    }
    if (bytes == null || !ref.mounted) return null;
    state = state.copyWith(preparingPhoto: true);
    try {
      final photo = await ref.read(recipePhotoProcessorProvider)(bytes);
      if (!ref.mounted) return null;
      state = state.copyWith(
        preparingPhoto: false,
        photoError: null,
        photoChange: ReplaceRecipePhoto(
          NewRecipePhoto(photoId: ref.read(newIdProvider)(), photo: photo),
        ),
      );
      return null;
    } on RecipePhotoFormatException {
      if (ref.mounted) state = state.copyWith(preparingPhoto: false);
      return RecipePhotoPickError.unreadable;
    }
  }

  /// Saca la foto: la elegida y todavía no subida se descarta; la guardada
  /// se saca al guardar.
  void removePhoto() {
    if (state.saving || state.preparingPhoto) return;
    state = state.copyWith(
      photoError: null,
      photoChange: state.savedPhotoId == null ? null : const RemoveRecipePhoto(),
    );
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

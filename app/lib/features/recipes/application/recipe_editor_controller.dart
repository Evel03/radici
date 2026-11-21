// Editor de un plato: el formulario (RecipeDraft) con sus cambios, el
// guardado entero por save_recipe, la foto y desactivar o reactivar.
//
// Un plato nuevo (o una copia) lleva un id generado al abrir el editor: cada
// reintento de guardar manda el mismo, así un guardado que llegó al servidor
// pero cuya respuesta se perdió no duplica el plato. Si falla, el formulario
// queda como estaba.
//
// El español es la fuente (20/11/2026): al guardar, antes de save_recipe, se
// traduce al italiano y al inglés lo que dice el plan
// (planRecipeTranslation: lo vacío y lo automático cuyo español cambió). Si
// el traductor falla no se guarda nada (tampoco la foto) y lo escrito queda;
// se puede reintentar, escribir a mano lo que falta o guardar sin traducir (lo
// automático viejo se vacía: nunca queda una traducción vieja como si fuera
// la del español nuevo).
//
// Un plato viejo (guardado sin el nombre en español) abre con su italiano en
// el español y el italiano vacío, para traducir (italianMovedToSpanish:
// Evelyn cargó los platos en español en el campo italiano). Si se guarda sin
// traducir, sigue siendo viejo: el español vuelve al campo italiano y
// name_es queda null (RecipeTranslationPlan.skippedToSave), así nunca hace
// falta escribir el italiano y la próxima vez que se guarde se traduce.
//
// La foto se elige en el mismo editor, también en un plato nuevo: queda
// preparada (achicada y sin metadatos) y se sube al guardar, después de la
// traducción y del plato (los archivos van en la carpeta del plato y
// set_recipe_photo exige que exista). Si la foto falla, el plato queda guardado
// y la foto sigue en el editor para reintentar, con el mismo uuid. Mientras se
// elige o se prepara una foto no se guarda; una que llega mientras guarda (en
// la web) queda para el próximo guardado y el editor no se cierra. El guardado
// sigue (plato, foto) aunque el editor se cierre: lo hace el catálogo, que no
// se descarta.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/application/recipe_photo_providers.dart';
import 'package:radici/features/recipes/data/recipe_photo_picker.dart';
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';
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

    /// En un plato viejo (como está guardado), los campos en italiano que
    /// abrieron vacíos porque su texto pasó al español
    /// (italianMovedToSpanish). Vacío en los demás.
    @Default(<TranslatedField>{}) Set<TranslatedField> movedToSpanish,

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

    /// La última negativa que no se arregla reintentando (422 o 429) y el
    /// pedido que la tuvo: con el mismo pedido, guardar no vuelve a llamar
    /// al traductor (un 429 rechazado también cuenta en el cupo).
    TranslationRefusal? refusal,

    /// Por qué el último guardado fue sin traducir sin preguntar (501 o 422
    /// con solo campos vacíos), para el aviso de la lista; null si no.
    TranslationFailureKind? untranslatedBecause,

    /// Se está desactivando o reactivando.
    @Default(false) bool changingActive,

    /// La foto que tiene guardada el plato (null = sin foto; también en uno
    /// nuevo y en una copia: duplicar no copia la foto).
    String? savedPhotoId,

    /// Lo que se cambia en la foto al guardar (null = nada).
    RecipePhotoChange? photoChange,

    /// Se está eligiendo o preparando una foto: en el teléfono, desde que se
    /// abre el selector (sigue cargando la foto, por ejemplo de iCloud, con el
    /// selector ya cerrado); en la web, desde que llega (ahí la cancelación
    /// puede no llegar nunca).
    @Default(false) bool preparingPhoto,

    /// El cambio de foto que se está guardando (mientras guarda, después del
    /// plato); null si no.
    RecipePhotoChange? photoInFlight,

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

  /// Se está subiendo (o sacando) la foto.
  bool get uploadingPhoto => photoInFlight != null;

  /// Traduciendo o guardando: no se puede volver a guardar ni salir.
  bool get busy => saving || translating;

  /// El nombre en español es obligatorio siempre: uno nuevo (o una copia) lo
  /// escribe, y uno guardado abre con él, el suyo o, en uno viejo, el que
  /// estaba en el campo italiano. El nombre en italiano vacío no falta si
  /// sale del español: lo traduce el guardado.
  RecipeDraftErrors get errors => validateRecipeDraft(
    draft,
    requireSpanish: true,
    willTranslate: true,
  );

  /// Qué se traduce (o se vacía) al guardar.
  RecipeTranslationPlan get translationPlan => planRecipeTranslation(
    draft,
    translatedFrom: translatedFrom,
    movedToSpanish: movedToSpanish,
  );

  @override
  String toString() => 'RecipeEditorState(${draft.id})';
}

/// Una negativa del traductor (422 o 429) y el pedido que la tuvo.
typedef TranslationRefusal = ({TranslationFailureKind kind, SpanishText request});

/// Resultado de [RecipeEditorController.save].
enum RecipeSaveResult {
  saved,

  /// Guardado sin traducir: la traducción automática está apagada (501) o
  /// no pudo con este texto (422), y lo único que había para traducir eran
  /// campos vacíos ([RecipeEditorState.untranslatedBecause] dice cuál).
  savedUntranslated,

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

  /// El plato se guardó, pero la foto no (ver
  /// [RecipeEditorState.photoError]): sigue en el editor para reintentar.
  photoFailed,

  /// Se guardó, pero mientras guardaba se eligió otra foto (o se está
  /// preparando): queda en el editor para guardarla, que no se cierra.
  photoPending,

  /// Ya se estaba guardando o traduciendo.
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

/// Ya hay otro plato con el nombre en español del editor: el aviso sale
/// debajo del nombre en español mientras se escribe (un plato nuevo empieza
/// por ahí). El de un plato viejo es el que está en el campo italiano (el
/// editor lo abre así: italianMovedToSpanish). Es un aviso: no impide
/// guardar.
final recipeSpanishNameTakenProvider = Provider.autoDispose
    .family<bool, RecipeEditorTarget>((ref, target) {
      final (id, name) = ref.watch(
        recipeEditorProvider(
          target,
        ).select((state) => (state.draft.id, state.draft.nameEs)),
      );
      final catalog = ref.watch(recipeCatalogProvider).value ?? const [];
      return hasRecipeNamed(
        catalog,
        name,
        exceptId: id,
        nameOf: (recipe) => recipe.nameEs ?? recipe.nameIt,
      );
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
      savedPhotoId: isNew ? null : source?.photoId,
      movedToSpanish: source == null
          ? const {}
          : italianMovedToSpanish(source, copy: target is CopyRecipe),
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

  /// «Deshacer» de [removeIngredient]: la fila vuelve a su lugar. Mientras
  /// traduce o guarda no hace nada (el aviso puede seguir a la vista): el
  /// cambio quedaría fuera del guardado.
  void restoreIngredient(RemovedIngredient removed) {
    if (state.busy) return;
    final rows = [...state.draft.ingredients];
    if (rows.any((row) => row.key == removed.row.key)) return;
    rows.insert(removed.index.clamp(0, rows.length), removed.row);
    _edit((d) => d.copyWith(ingredients: rows));
  }

  /// Valida, traduce lo que diga el plan y guarda el plato entero y, si
  /// cambió, la foto. Con errores no manda nada y los muestra. Mientras se
  /// elige o se prepara una foto no guarda. Si el traductor falla, no guarda
  /// nada (tampoco la foto) y el formulario queda como estaba
  /// ([RecipeSaveResult.translationFailed]), salvo con la traducción apagada
  /// (501) o un texto que no se puede traducir (422) y solo campos vacíos para
  /// traducir: ahí guarda sin traducir, porque no queda nada viejo
  /// ([RecipeSaveResult.savedUntranslated]). Después de un 422 o un 429, con
  /// el mismo pedido no vuelve a llamar al traductor. Si el servidor falla al
  /// guardar, el formulario queda (con la traducción, que no se vuelve a pedir)
  /// y el próximo intento manda el mismo id. Si solo cambió la foto de un
  /// plato ya guardado (por ejemplo, el reintento después de que falló la
  /// foto) y no hay nada que traducir, no vuelve a mandar el plato.
  Future<RecipeSaveResult> save() async {
    if (state.busy || state.preparingPhoto) return RecipeSaveResult.busy;
    if (!_validate()) return RecipeSaveResult.invalid;
    final plan = state.translationPlan;
    // Sin nada que traducir puede haber descripciones automáticas que vaciar
    // (se borró la española).
    if (!plan.needsTranslation) return _persistSkipped(plan);
    final request = plan.request;
    final refusal = state.refusal;
    // El mismo pedido ya tuvo un 422 o un 429: reintentar no sirve (y un 429
    // gasta cupo).
    if (refusal != null && refusal.request == request) {
      return _translationFailed(plan, refusal.kind);
    }
    state = state.copyWith(
      translating: true,
      saveError: null,
      translateError: null,
    );
    final RecipeTranslation translation;
    try {
      translation = await ref
          .read(translationRepositoryProvider)
          .translate(request);
    } on TranslationFailure catch (failure) {
      if (!ref.mounted) return RecipeSaveResult.translationFailed;
      final kind = failure.kind;
      state = state.copyWith(
        translating: false,
        refusal:
            kind == TranslationFailureKind.untranslatable ||
                kind == TranslationFailureKind.rateLimited
            ? (kind: kind, request: request)
            : state.refusal,
      );
      return _translationFailed(plan, kind);
    }
    if (!ref.mounted) return RecipeSaveResult.stale;
    state = state.copyWith(translating: false, refusal: null);
    // La pantalla no deja escribir mientras traduce; si igual cambió algo, la
    // traducción no lo pisa.
    if (state.draft != plan.draft) return RecipeSaveResult.stale;
    return _persist(plan.translated(translation));
  }

  /// La traducción falló con [kind]. Apagada (501) o un texto que no se
  /// puede traducir (422) con solo campos vacíos: no queda nada viejo, así
  /// que guarda sin traducir y la lista lo dice (un plato viejo, como viejo).
  /// Si no, o si así el plato saldría de la web (un plato viejo con el nombre
  /// en italiano escrito a mano y la descripción que había pasado al
  /// español), no guarda y [RecipeEditorState.translateError] dice por qué.
  Future<RecipeSaveResult> _translationFailed(
    RecipeTranslationPlan plan,
    TranslationFailureKind kind,
  ) async {
    if ((kind == TranslationFailureKind.notConfigured ||
            kind == TranslationFailureKind.untranslatable) &&
        plan.fillsOnlyEmpty &&
        plan.canSkip &&
        !plan.skipEmptiesItalianDescription &&
        state.draft == plan.draft) {
      final result = await _persistSkipped(plan, untranslatedBecause: kind);
      return result == RecipeSaveResult.saved
          ? RecipeSaveResult.savedUntranslated
          : result;
    }
    state = state.copyWith(translateError: kind);
    return RecipeSaveResult.translationFailed;
  }

  /// Guarda sin traducir, después de una traducción que falló: lo
  /// automático que había que traducir de nuevo queda vacío (nunca una
  /// traducción vieja como si fuera la del español nuevo), lo vacío queda
  /// vacío y lo escrito a mano, como estaba; un plato viejo sigue siendo
  /// viejo ([RecipeTranslationPlan.skippedToSave]). Sin el nombre en
  /// italiano no se puede ([RecipeTranslationPlan.canSkip]): no manda nada.
  /// La foto se guarda como con [save].
  Future<RecipeSaveResult> saveWithoutTranslating() async {
    if (state.busy || state.preparingPhoto) return RecipeSaveResult.busy;
    if (!_validate()) return RecipeSaveResult.invalid;
    final plan = state.translationPlan;
    if (!plan.canSkip) return RecipeSaveResult.invalid;
    return _persistSkipped(plan);
  }

  /// Guarda sin traducir lo que diga [plan]: el formulario queda como
  /// [RecipeTranslationPlan.skipped] (lo que quedó por traducir, vacío: se
  /// traduce la próxima vez) y se guarda
  /// [RecipeTranslationPlan.skippedToSave] (en un plato viejo que sigue
  /// viejo, el español en el italiano y name_es en null).
  Future<RecipeSaveResult> _persistSkipped(
    RecipeTranslationPlan plan, {
    TranslationFailureKind? untranslatedBecause,
  }) => _persist(
    plan.skipped,
    stored: plan.skippedToSave,
    untranslatedBecause: untranslatedBecause,
  );

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

  /// Guarda [draft] (ya traducido o sin traducir) con save_recipe, o
  /// [stored] si lo que se guarda no es lo que muestra el formulario (un
  /// plato viejo que sigue viejo), y después, si cambió, la foto. El
  /// formulario pasa a [draft]: sus campos automáticos salen del español de
  /// [draft], se guarde o no; si falla, queda así para reintentar.
  /// [untranslatedBecause]: se guarda sin traducir sin preguntar, por eso.
  /// Si solo cambió la foto de un plato ya guardado, no vuelve a mandar el
  /// plato.
  Future<RecipeSaveResult> _persist(
    RecipeDraft draft, {
    RecipeDraft? stored,
    TranslationFailureKind? untranslatedBecause,
  }) async {
    // Antes del primer await del guardado: si el editor se cierra mientras
    // guarda, el catálogo (que no se descarta) termina de guardar el plato y
    // la foto.
    final catalog = ref.read(recipeCatalogProvider.notifier);
    final photoChange = state.photoChange;
    final recipeChanged =
        state.isNew || draft != state.initial || photoChange == null;
    state = state.copyWith(
      draft: draft,
      translatedFrom: spanishTextOf(draft),
      saving: true,
      saveError: null,
      translateError: null,
      untranslatedBecause: null,
      photoError: null,
    );
    if (recipeChanged) {
      final recipe = recipeFromDraft(
        stored ?? draft,
        saved: state.isNew ? null : state.source,
      );
      try {
        final saved = await catalog.save(recipe);
        if (ref.mounted) {
          state = state.copyWith(
            saving: photoChange != null,
            initial: draft,
            source: saved,
            isNew: false,
            untranslatedBecause: untranslatedBecause,
            // Como quedó guardado: si sigue viejo, el formulario es el mismo
            // con que se volvería a abrir.
            movedToSpanish: italianMovedToSpanish(saved),
          );
        }
      } on RecipesFailure catch (failure) {
        if (ref.mounted) {
          state = state.copyWith(saving: false, saveError: failure.kind);
        }
        return RecipeSaveResult.failed;
      }
    } else {
      // Solo cambió la foto: el plato guardado ya es este.
      state = state.copyWith(untranslatedBecause: untranslatedBecause);
    }
    final result = photoChange == null
        ? RecipeSaveResult.saved
        : await _savePhoto(catalog, draft.id, photoChange);
    // Mientras guardaba llegó otra foto (en la web, una elegida justo antes de
    // tocar «Salva»): no se guardó, así que el editor no se cierra.
    if (result == RecipeSaveResult.saved &&
        ref.mounted &&
        (state.photoChange != null || state.preparingPhoto)) {
      return RecipeSaveResult.photoPending;
    }
    return result;
  }

  /// Guarda [change] en el plato [recipeId] por [catalog], también si el
  /// editor se cerró. Al terminar, el editor deja de tener pendiente [change]
  /// solo si sigue siendo el suyo: una foto elegida mientras tanto queda.
  Future<RecipeSaveResult> _savePhoto(
    RecipeCatalogController catalog,
    String recipeId,
    RecipePhotoChange change,
  ) async {
    final photo = switch (change) {
      ReplaceRecipePhoto(:final photo) => photo,
      RemoveRecipePhoto() => null,
    };
    if (ref.mounted) state = state.copyWith(photoInFlight: change);
    try {
      await catalog.setPhoto(recipeId, photo);
      if (ref.mounted) {
        state = state.copyWith(
          saving: false,
          photoInFlight: null,
          photoChange: state.photoChange == change ? null : state.photoChange,
          savedPhotoId: photo?.photoId,
          source: state.source?.copyWith(photoId: photo?.photoId),
        );
      }
      return RecipeSaveResult.saved;
    } on RecipePhotoFailure catch (failure) {
      if (!ref.mounted) return RecipeSaveResult.photoFailed;
      final stillPending = state.photoChange == change;
      state = state.copyWith(
        saving: false,
        photoInFlight: null,
        photoError: stillPending ? failure.kind : null,
      );
      // Si ya se eligió otra, esta no importa: queda la nueva para guardar.
      return stillPending
          ? RecipeSaveResult.photoFailed
          : RecipeSaveResult.photoPending;
    }
  }

  /// Abre el selector en [source] y prepara la foto elegida (derecha,
  /// achicada y sin metadatos), con un uuid nuevo: se sube al guardar, en
  /// lugar de la que tenga. Devuelve por qué no quedó (null si quedó o si se
  /// canceló).
  Future<RecipePhotoPickError?> pickPhoto(RecipePhotoSource source) async {
    if (state.saving || state.preparingPhoto) return null;
    final picker = ref.read(recipePhotoPickerProvider);
    final processor = ref.read(recipePhotoProcessorProvider);
    final newId = ref.read(newIdProvider);
    // En el teléfono el selector siempre termina, también si se cancela: la
    // foto cuenta como «preparando» desde que se abre (y mientras carga con el
    // selector ya cerrado), así «Salva» espera y un segundo toque no cancela
    // el primero. En la web, si se cancela en un navegador sin el evento
    // cancel, el selector no termina nunca y la marca dejaría todo trabado:
    // ahí se marca recién cuando llega la foto.
    final markWhilePicking = !ref.read(isWebProvider);
    if (markWhilePicking) state = state.copyWith(preparingPhoto: true);
    void stopPicking() {
      if (markWhilePicking && ref.mounted) {
        state = state.copyWith(preparingPhoto: false);
      }
    }

    final Uint8List? bytes;
    try {
      bytes = await picker.pick(source);
    } on RecipePhotoPickFailure catch (failure) {
      stopPicking();
      return switch (failure.kind) {
        RecipePhotoPickFailureKind.permissionDenied =>
          RecipePhotoPickError.permissionDenied,
        RecipePhotoPickFailureKind.unavailable =>
          RecipePhotoPickError.unavailable,
      };
    }
    if (bytes == null) {
      stopPicking();
      return null;
    }
    if (!ref.mounted) return null;
    // Si mientras tanto empezó a guardar (en la web: sin marca mientras elige),
    // el guardado en curso ya tomó su cambio de foto y no toca esta: queda
    // para el próximo guardado y, como sigue «preparando», el editor no se
    // cierra al terminar.
    state = state.copyWith(preparingPhoto: true);
    try {
      final photo = await processor(bytes);
      if (!ref.mounted) return null;
      state = state.copyWith(
        preparingPhoto: false,
        photoError: null,
        photoChange: ReplaceRecipePhoto(
          NewRecipePhoto(photoId: newId(), photo: photo),
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

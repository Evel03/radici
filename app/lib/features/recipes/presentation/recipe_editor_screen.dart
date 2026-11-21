// Editor de un plato del catálogo, a pantalla completa. Primero lo rápido:
// el nombre y la descripción de la web en español (la fuente de la traducción
// automática, 20/11/2026), los alérgenos, la dieta y la temporada; después el
// italiano y el inglés (nombre y descripción), que llena la traducción al
// guardar, con la marca «tradotto automaticamente» en lo que no se tocó a
// mano (sin la descripción italiana el plato no sale en el formulario de
// pedido), y la foto (también en un plato nuevo: se sube al guardar, después
// de la traducción y del plato); y lo opcional: conservación, ingredientes con
// su cantidad para 4 porciones y notas. «Salva» queda abajo, siempre a mano
// (con el teclado abierto, justo arriba de él); mientras traduce dice que
// traduce y el formulario no se puede tocar. Si la traducción falla, un aviso
// ofrece reintentar, escribir a mano o guardar sin traducir. Un plato guardado
// se puede duplicar y desactivar (nunca se borra). Solo muestra providers: la
// lógica está en RecipeEditorController.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/application/recipe_editor_controller.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/domain/recipe_translation.dart';
import 'package:radici/features/recipes/presentation/ingredient_row.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
import 'package:radici/features/recipes/presentation/recipe_photo_section.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

class RecipeEditorScreen extends ConsumerWidget {
  const RecipeEditorScreen({super.key, required this.target});

  final RecipeEditorTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // Para editar o copiar hace falta el catálogo (un enlace directo puede
    // llegar antes de que cargue).
    return ref
        .watch(recipeCatalogProvider)
        .when(
          loading: () => Scaffold(
            appBar: AppBar(title: Text(l10n.recipesTitle)),
            body: const Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => Scaffold(
            appBar: AppBar(title: Text(l10n.recipesTitle)),
            body: LoadErrorView(
              message: l10n.recipesLoadFailed,
              onRetry: () => ref.invalidate(recipeCatalogProvider),
            ),
          ),
          data: (recipes) {
            final sourceId = switch (target) {
              CreateRecipe() => null,
              EditRecipe(:final id) => id,
              CopyRecipe(:final sourceId) => sourceId,
            };
            if (sourceId != null && !recipes.any((r) => r.id == sourceId)) {
              return const _RecipeNotFound();
            }
            return _RecipeEditor(target: target);
          },
        );
  }
}

class _RecipeEditor extends ConsumerStatefulWidget {
  const _RecipeEditor({required this.target});

  final RecipeEditorTarget target;

  @override
  ConsumerState<_RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends ConsumerState<_RecipeEditor> {
  /// Avisos propios: quedan en el editor (con el de la app seguirían a la
  /// vista en la lista al cerrarlo, tapando su botón flotante).
  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();

  late final TextEditingController _nameIt;
  late final TextEditingController _nameEs;
  late final TextEditingController _nameEn;
  late final TextEditingController _descriptionIt;
  late final TextEditingController _descriptionEs;
  late final TextEditingController _descriptionEn;
  late final TextEditingController _fridgeDays;
  late final TextEditingController _freezerDays;
  late final TextEditingController _notes;

  /// Los campos en italiano y en inglés: «Scrivo io» enfoca el primero que
  /// había que traducir.
  final Map<TranslatedField, FocusNode> _translationFocus = {
    for (final field in TranslatedField.values) field: FocusNode(),
  };

  /// Los campos de cada fila de ingrediente, por su clave.
  final Map<int, IngredientRowControllers> _rows = {};

  /// Para llevar a la vista el primer campo con error.
  final GlobalKey _nameKey = GlobalKey();
  final GlobalKey _dietKey = GlobalKey();
  final GlobalKey _descriptionKey = GlobalKey();
  final GlobalKey _photoKey = GlobalKey();
  final GlobalKey _translationsKey = GlobalKey();
  final GlobalKey _storageKey = GlobalKey();
  final GlobalKey _notesKey = GlobalKey();

  RecipeEditorController get _editor =>
      ref.read(recipeEditorProvider(widget.target).notifier);

  RecipeEditorState get _state => ref.read(recipeEditorProvider(widget.target));

  @override
  void initState() {
    super.initState();
    // Los campos arrancan con el formulario tal como se abrió; después cada
    // cambio va al controller.
    final opened = _state.draft;
    _nameIt = TextEditingController(text: opened.nameIt);
    _nameEs = TextEditingController(text: opened.nameEs);
    _nameEn = TextEditingController(text: opened.nameEn);
    _descriptionIt = TextEditingController(text: opened.descriptionIt);
    _descriptionEs = TextEditingController(text: opened.descriptionEs);
    _descriptionEn = TextEditingController(text: opened.descriptionEn);
    _fridgeDays = TextEditingController(text: opened.fridgeDays);
    _freezerDays = TextEditingController(text: opened.freezerDays);
    _notes = TextEditingController(text: opened.notes);
    // El italiano y el inglés también los cambia el guardado (la traducción,
    // o vaciar lo automático): los campos muestran lo que tiene el formulario.
    ref.listenManual(
      recipeEditorProvider(widget.target).select((state) => state.draft),
      (_, draft) {
        _syncText(_nameIt, draft.nameIt);
        _syncText(_descriptionIt, draft.descriptionIt);
        _syncText(_nameEn, draft.nameEn);
        _syncText(_descriptionEn, draft.descriptionEn);
      },
    );
  }

  void _syncText(TextEditingController controller, String text) {
    if (controller.text == text) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  void dispose() {
    for (final controller in [
      _nameIt,
      _nameEs,
      _nameEn,
      _descriptionIt,
      _descriptionEs,
      _descriptionEn,
      _fridgeDays,
      _freezerDays,
      _notes,
    ]) {
      controller.dispose();
    }
    for (final node in _translationFocus.values) {
      node.dispose();
    }
    for (final row in _rows.values) {
      row.dispose();
    }
    super.dispose();
  }

  IngredientRowControllers _rowFor(IngredientDraft row) =>
      _rows.putIfAbsent(row.key, () => IngredientRowControllers(row));

  void _show(SnackBar snackBar) {
    final messenger = _messenger.currentState;
    if (messenger == null) return;
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(snackBar);
  }

  /// Con VoiceOver o TalkBack el aviso no se va solo: se cierra con la X.
  bool get _persist => MediaQuery.accessibleNavigationOf(context);

  /// Guarda (traduciendo lo que haga falta) o, con [translate] en false,
  /// guarda sin traducir.
  Future<void> _save({bool translate = true}) async {
    FocusScope.of(context).unfocus();
    // El aviso de antes (un «Annulla») no sigue a mano mientras guarda.
    _messenger.currentState?.removeCurrentSnackBar();
    final l10n = AppLocalizations.of(context);
    final result = translate
        ? await _editor.save()
        : await _editor.saveWithoutTranslating();
    if (!mounted) return;
    final state = _state;
    switch (result) {
      case RecipeSaveResult.saved || RecipeSaveResult.savedUntranslated:
        // La lista lo avisa (este editor se cierra), y si se guardó sin
        // traducir sin preguntar, también dice por qué.
        final saved = state.source;
        if (saved != null) {
          ref
              .read(recipeSavedNoticeProvider.notifier)
              .post(
                saved,
                untranslatedBecause: result == RecipeSaveResult.savedUntranslated
                    ? state.untranslatedBecause
                    : null,
              );
        }
        Navigator.of(context).pop();
      case RecipeSaveResult.invalid:
        _show(SnackBar(content: Text(l10n.recipeFixErrors)));
        _revealFirstError(state);
      case RecipeSaveResult.failed:
        final retry = state.saveError == RecipesFailureKind.unavailable;
        _show(
          SnackBar(
            content: Text(switch (state.saveError) {
              RecipesFailureKind.invalid => l10n.recipeSaveRejected,
              RecipesFailureKind.notFound => l10n.recipeSaveNotFound,
              _ => l10n.recipeSaveFailed,
            }),
            duration: errorSnackBarDuration,
            persist: _persist,
            showCloseIcon: _persist,
            action: retry
                ? SnackBarAction(
                    label: l10n.actionRetry,
                    onPressed: () => unawaited(_save()),
                  )
                : null,
          ),
        );
      case RecipeSaveResult.translationFailed:
        await _translationFailed(state);
      case RecipeSaveResult.stale:
        // Nunca se descarta un guardado en silencio.
        _show(
          SnackBar(
            content: Text(l10n.recipeSaveInterrupted),
            duration: errorSnackBarDuration,
            persist: _persist,
            showCloseIcon: _persist,
          ),
        );
      case RecipeSaveResult.photoFailed || RecipeSaveResult.photoPending:
        // El plato se guardó, pero no se cierra: la foto falló (la sección lo
        // dice, con su «Riprova») o se eligió otra mientras guardaba (queda
        // para guardar). La sección se lleva a la vista. Sin aviso abajo: con
        // el texto grande se desbordaba y tapaba el «Riprova» de la sección.
        final photo = _photoKey.currentContext;
        if (photo != null && photo.mounted) {
          unawaited(
            Scrollable.ensureVisible(
              photo,
              duration: const Duration(milliseconds: 300),
              alignment: 0.1,
            ),
          );
        }
      case RecipeSaveResult.busy:
        break;
    }
  }

  /// La traducción falló: no se guardó nada. Dice por qué y ofrece
  /// reintentar (si puede andar), guardar sin traducir (si el nombre en
  /// italiano no queda vacío) o escribir a mano.
  Future<void> _translationFailed(RecipeEditorState state) async {
    final kind = state.translateError;
    if (kind == null) return;
    final l10n = AppLocalizations.of(context);
    final plan = state.translationPlan;
    final cause = switch (kind) {
      TranslationFailureKind.unavailable => l10n.recipeTranslateUnavailable,
      TranslationFailureKind.offline => l10n.recipeTranslateOffline,
      TranslationFailureKind.timeout => l10n.recipeTranslateTimeout,
      TranslationFailureKind.untranslatable =>
        l10n.recipeTranslateUntranslatable,
      TranslationFailureKind.notConfigured => l10n.recipeTranslateNotConfigured,
      TranslationFailureKind.rateLimited => l10n.recipeTranslateRateLimited,
      TranslationFailureKind.unauthorized => l10n.recipeTranslateSessionExpired,
      TranslationFailureKind.server ||
      TranslationFailureKind.forbidden ||
      TranslationFailureKind.invalid => l10n.recipeTranslateBroken,
    };
    // Un plato viejo que sigue viejo queda como estaba (con el español en el
    // italiano): el aviso no dice que lo que hay que traducir queda vacío.
    final next = plan.canSkip
        ? [
            if (plan.skipKeepsOld)
              l10n.recipeTranslateSkipKeepsItalian
            else
              l10n.recipeTranslateSkipHint,
            if (plan.skipEmptiesItalianDescription)
              l10n.recipeTranslateSkipOffWeb,
          ].join(' ')
        : l10n.recipeTranslateNeedsItalianName;
    final choice = await showDialog<_AfterTranslateFailure>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('recipe-translate-failed'),
        scrollable: true,
        title: Text(l10n.recipeTranslateFailedTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(cause, key: const ValueKey('recipe-translate-cause')),
            const SizedBox(height: 12),
            Text(next, key: const ValueKey('recipe-translate-next')),
          ],
        ),
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(
            key: const ValueKey('recipe-translate-write'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_AfterTranslateFailure.write),
            child: Text(l10n.recipeTranslateWrite),
          ),
          if (plan.canSkip)
            TextButton(
              key: const ValueKey('recipe-translate-skip'),
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_AfterTranslateFailure.skip),
              child: Text(l10n.recipeTranslateSkip),
            ),
          if (kind.canRetry)
            FilledButton(
              key: const ValueKey('recipe-translate-retry'),
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_AfterTranslateFailure.retry),
              child: Text(l10n.actionRetry),
            ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _AfterTranslateFailure.retry:
        await _save();
      case _AfterTranslateFailure.skip:
        await _save(translate: false);
      case _AfterTranslateFailure.write || null:
        _revealTranslations(plan);
    }
  }

  /// Enfoca el primer campo en italiano o en inglés que había que traducir
  /// (con el teclado, para escribirlo) y lo lleva a la vista.
  void _revealTranslations(RecipeTranslationPlan plan) {
    final field = TranslatedField.values.firstWhere(
      plan.translate.contains,
      orElse: () => TranslatedField.nameIt,
    );
    final node = _translationFocus[field]!..requestFocus();
    final target = node.context ?? _translationsKey.currentContext;
    if (target == null) return;
    unawaited(
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 300),
        alignment: 0.1,
      ),
    );
  }

  /// Lleva a la vista el primer campo con error, en el orden del formulario.
  void _revealFirstError(RecipeEditorState state) {
    final errors = state.errors;
    final firstRow = state.draft.ingredients
        .where((row) => errors.ingredients.containsKey(row.key))
        .firstOrNull;
    final key = switch (errors) {
      _ when errors.nameEs != null => _nameKey,
      _ when errors.descriptionEs != null => _descriptionKey,
      _ when errors.dietConflicts.isNotEmpty => _dietKey,
      _
          when errors.nameIt != null ||
              errors.descriptionIt != null ||
              errors.nameEn != null ||
              errors.descriptionEn != null =>
        _translationsKey,
      _ when errors.fridgeDays || errors.freezerDays => _storageKey,
      _ when firstRow != null => _rows[firstRow.key]?.anchor,
      _ when errors.notes != null => _notesKey,
      _ => null,
    };
    final target = key?.currentContext;
    if (target == null) return;
    unawaited(
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 300),
        alignment: 0.1,
      ),
    );
  }

  void _addIngredient() {
    final key = _editor.addIngredient();
    if (key == null) return;
    // La fila nueva, a la vista y lista para escribir.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _rows[key];
      if (!mounted || row == null) return;
      row.nameFocus.requestFocus();
      final target = row.anchor.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 200),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ),
        );
      }
    });
  }

  void _removeIngredient(int key) {
    final l10n = AppLocalizations.of(context);
    final removed = _editor.removeIngredient(key);
    if (removed == null) return;
    // Sus campos se descartan después de este cuadro (todavía están en
    // pantalla); «Annulla» la vuelve a armar con lo que tenía.
    final controllers = _rows.remove(key);
    if (controllers != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => controllers.dispose());
    }
    _show(
      SnackBar(
        content: Text(l10n.recipeIngredientRemoved),
        duration: undoSnackBarDuration,
        persist: _persist,
        showCloseIcon: _persist,
        action: SnackBarAction(
          label: l10n.actionUndo,
          onPressed: () => _editor.restoreIngredient(removed),
        ),
      ),
    );
  }

  /// Elegir «q.b.» borra la cantidad: no lleva.
  void _setUnit(int key, UnitChoice unit) {
    if (unit == UnitChoice.toTaste) _rows[key]?.quantity.clear();
    _editor.updateIngredient(
      key,
      unit: unit,
      quantity: unit == UnitChoice.toTaste ? '' : null,
    );
  }

  Future<void> _setActive({required bool active}) async {
    final l10n = AppLocalizations.of(context);
    try {
      await _editor.setActive(active: active);
      if (!mounted) return;
      _show(
        SnackBar(
          content: Text(
            active ? l10n.recipeReactivatedDone : l10n.recipeDeactivatedDone,
          ),
          duration: undoSnackBarDuration,
          persist: _persist,
          showCloseIcon: _persist,
          action: SnackBarAction(
            label: l10n.actionUndo,
            onPressed: () => unawaited(_setActive(active: !active)),
          ),
        ),
      );
    } on RecipesFailure {
      if (!mounted) return;
      _show(
        SnackBar(
          content: Text(l10n.recipeActiveFailed),
          duration: errorSnackBarDuration,
          persist: _persist,
          showCloseIcon: _persist,
          action: SnackBarAction(
            label: l10n.actionRetry,
            onPressed: () => unawaited(_setActive(active: active)),
          ),
        ),
      );
    }
  }

  /// Abre la copia del plato guardado (con un id nuevo). Si hay cambios sin
  /// guardar, primero pregunta si se descartan.
  Future<void> _duplicate() async {
    final state = _state;
    if (state.dirty && !await _confirmDiscard()) return;
    if (!mounted) return;
    context.go(AppRoutes.recipeCopy(state.draft.id));
  }

  Future<bool> _confirmDiscard() async {
    final l10n = AppLocalizations.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('recipe-discard-dialog'),
        title: Text(l10n.recipeDiscardTitle),
        content: Text(l10n.recipeDiscardBody),
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(
            key: const ValueKey('recipe-discard-keep'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.recipeDiscardKeep),
          ),
          FilledButton(
            key: const ValueKey('recipe-discard-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.recipeDiscardConfirm),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  /// Volver con cambios sin guardar: pregunta antes de descartarlos.
  Future<void> _confirmLeave() async {
    if (_state.busy) return;
    if (await _confirmDiscard() && mounted) Navigator.of(context).pop();
  }

  String? _textError(
    AppLocalizations l10n,
    TextError? error,
    int max, {
    String? required,
  }) => switch (error) {
    null => null,
    TextError.required => required,
    TextError.tooLong => l10n.recipeTextTooLong(max),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RecipeFormats(context);
    final state = ref.watch(recipeEditorProvider(widget.target));
    final nameTaken = ref.watch(recipeNameTakenProvider(widget.target));
    final spanishNameTaken = ref.watch(
      recipeSpanishNameTakenProvider(widget.target),
    );
    final target = widget.target;
    // Si está activo se lee del catálogo: desactivar no pasa por el formulario.
    final saved = switch (target) {
      EditRecipe(:final id) => ref.watch(recipeByIdProvider(id)),
      _ => null,
    };
    final inactive = saved != null && !saved.active;
    final draft = state.draft;
    final errors = state.errors;
    final show = state.showErrors;
    Widget? autoMark(TranslatedField field) =>
        draft.autoTranslated.contains(field)
        ? _AutoTranslatedMark(key: ValueKey('recipe-auto-${field.dbValue}'))
        : null;

    final title = switch (target) {
      CreateRecipe() => l10n.recipeNew,
      EditRecipe() => l10n.recipeEditTitle,
      CopyRecipe() => l10n.recipeCopyTitle,
    };

    final form = <Widget>[
      if (inactive)
        _InactiveBanner(
          onReactivate: state.changingActive
              ? null
              : () => unawaited(_setActive(active: true)),
        ),
      if (target is CopyRecipe && state.source != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            l10n.recipeCopyHint(state.source!.nameIt),
            key: const ValueKey('recipe-copy-hint'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      KeyedSubtree(
        key: _nameKey,
        child: TextField(
          key: const ValueKey('recipe-name-es'),
          controller: _nameEs,
          autofocus: target is! EditRecipe,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.next,
          onChanged: _editor.setNameEs,
          decoration: InputDecoration(
            labelText: l10n.recipeNameEsLabel,
            helperText: spanishNameTaken
                ? l10n.recipeNameTaken
                : l10n.recipeNameEsHelper,
            helperMaxLines: 3,
            errorText: show
                ? _textError(
                    l10n,
                    errors.nameEs,
                    maxRecipeNameLength,
                    required: l10n.recipeNameEsRequired,
                  )
                : null,
            errorMaxLines: 2,
          ),
        ),
      ),
      KeyedSubtree(
        key: _descriptionKey,
        child: _SectionTitle(l10n.recipeDescriptionSection),
      ),
      _Hint(l10n.recipeDescriptionHelp),
      _DescriptionField(
        fieldKey: const ValueKey('recipe-description-es'),
        controller: _descriptionEs,
        label: l10n.recipeDescriptionEsLabel,
        error: show
            ? _textError(l10n, errors.descriptionEs, maxRecipeDescriptionLength)
            : null,
        textInputAction: TextInputAction.done,
        onChanged: _editor.setDescriptionEs,
      ),
      // Lo escrito en español va a Anthropic para traducirlo (SPEC §6).
      _Hint(
        l10n.recipePrivacyHint,
        key: const ValueKey('recipe-privacy-hint'),
      ),
      _SectionTitle(l10n.recipeAllergensSection),
      Wrap(
        spacing: 8,
        children: [
          for (final allergen in Allergen.values)
            FilterChip(
              key: ValueKey('recipe-allergen-${allergen.name}'),
              label: Text(l10n.allergen(allergen)),
              selected: draft.allergens.contains(allergen),
              onSelected: (_) => _editor.toggleAllergen(allergen),
            ),
        ],
      ),
      if (draft.allergens.isEmpty) _Hint(l10n.recipeAllergensNone),
      KeyedSubtree(key: _dietKey, child: _SectionTitle(l10n.recipeDietSection)),
      Wrap(
        spacing: 8,
        children: [
          for (final (name, diet, label) in [
            ('none', null, l10n.recipeDietNone),
            ('vegetarian', Diet.vegetarian, l10n.dietVegetarian),
            ('vegan', Diet.vegan, l10n.dietVegan),
          ])
            ChoiceChip(
              key: ValueKey('recipe-diet-$name'),
              label: Text(label),
              selected: draft.diet == diet,
              onSelected: (_) => _editor.setDiet(diet),
            ),
        ],
      ),
      // Se avisa enseguida, no recién al guardar: es un dato de salud.
      if (draft.diet case final diet? when errors.dietConflicts.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            l10n.dietConflict(diet, errors.dietConflicts),
            key: const ValueKey('recipe-diet-conflict'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      _SectionTitle(l10n.recipeSeasonSection),
      _Hint(l10n.recipeSeasonHelp, bottom: 4),
      Wrap(
        spacing: 8,
        children: [
          FilterChip(
            key: const ValueKey('recipe-all-year'),
            label: Text(l10n.recipeAllYear),
            selected: draft.months.isEmpty,
            onSelected: (_) => _editor.setAllYear(),
          ),
          for (var month = 1; month <= 12; month++)
            FilterChip(
              key: ValueKey('recipe-month-$month'),
              label: Text(
                formats.monthShort(month),
                semanticsLabel: formats.monthLong(month),
              ),
              selected: draft.months.contains(month),
              onSelected: (_) => _editor.toggleMonth(month),
            ),
        ],
      ),
      KeyedSubtree(
        key: _translationsKey,
        child: _SectionTitle(l10n.recipeTranslationsSection),
      ),
      _Hint(l10n.recipeTranslationsHelp, bottom: 4),
      TextField(
        key: const ValueKey('recipe-name-it'),
        controller: _nameIt,
        focusNode: _translationFocus[TranslatedField.nameIt],
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.next,
        onChanged: _editor.setNameIt,
        decoration: InputDecoration(
          labelText: l10n.recipeNameItLabel,
          // Automático: la marca, y debajo el aviso del nombre repetido si lo
          // hay. Escrito a mano: el aviso o la ayuda.
          helper: draft.autoTranslated.contains(TranslatedField.nameIt)
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    autoMark(TranslatedField.nameIt)!,
                    if (nameTaken)
                      Text(
                        l10n.recipeNameTaken,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                )
              : null,
          helperText: draft.autoTranslated.contains(TranslatedField.nameIt)
              ? null
              : nameTaken
              ? l10n.recipeNameTaken
              : l10n.recipeNameItHelper,
          helperMaxLines: 2,
          errorText: show
              ? _textError(
                  l10n,
                  errors.nameIt,
                  maxRecipeNameLength,
                  required: l10n.recipeNameRequired,
                )
              : null,
          errorMaxLines: 2,
        ),
      ),
      _DescriptionField(
        fieldKey: const ValueKey('recipe-description-it'),
        controller: _descriptionIt,
        focusNode: _translationFocus[TranslatedField.descriptionIt],
        label: l10n.recipeDescriptionItLabel,
        helper: autoMark(TranslatedField.descriptionIt),
        error: show
            ? _textError(l10n, errors.descriptionIt, maxRecipeDescriptionLength)
            : null,
        textInputAction: TextInputAction.next,
        onChanged: _editor.setDescriptionIt,
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('recipe-name-en'),
        controller: _nameEn,
        focusNode: _translationFocus[TranslatedField.nameEn],
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.next,
        onChanged: _editor.setNameEn,
        decoration: InputDecoration(
          labelText: l10n.recipeNameEnLabel,
          helper: autoMark(TranslatedField.nameEn),
          errorText: show
              ? _textError(l10n, errors.nameEn, maxRecipeNameLength)
              : null,
        ),
      ),
      _DescriptionField(
        fieldKey: const ValueKey('recipe-description-en'),
        controller: _descriptionEn,
        focusNode: _translationFocus[TranslatedField.descriptionEn],
        label: l10n.recipeDescriptionEnLabel,
        helper: autoMark(TranslatedField.descriptionEn),
        error: show
            ? _textError(l10n, errors.descriptionEn, maxRecipeDescriptionLength)
            : null,
        textInputAction: TextInputAction.done,
        onChanged: _editor.setDescriptionEn,
      ),
      KeyedSubtree(
        key: _photoKey,
        child: _SectionTitle(l10n.recipePhotoSection),
      ),
      RecipePhotoSection(target: target, onRetry: () => unawaited(_save())),
      const Divider(height: 48),
      Semantics(
        header: true,
        child: Text(l10n.recipeOptionalSection, style: theme.textTheme.titleMedium),
      ),
      KeyedSubtree(
        key: _storageKey,
        child: _SectionTitle(l10n.recipeStorageSection),
      ),
      _DaysField(
        fieldKey: const ValueKey('recipe-fridge-days'),
        controller: _fridgeDays,
        label: l10n.recipeFridgeDaysLabel,
        maxDigits: 2,
        error: show && errors.fridgeDays
            ? l10n.recipeDaysRange(0, maxFridgeDays)
            : null,
        onChanged: _editor.setFridgeDays,
      ),
      SwitchListTile(
        key: const ValueKey('recipe-freezable'),
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.recipeFreezableLabel),
        value: draft.freezable,
        onChanged: _editor.setFreezable,
      ),
      if (draft.freezable)
        _DaysField(
          fieldKey: const ValueKey('recipe-freezer-days'),
          controller: _freezerDays,
          label: l10n.recipeFreezerDaysLabel,
          maxDigits: 3,
          error: show && errors.freezerDays
              ? l10n.recipeDaysRange(1, maxFreezerDays)
              : null,
          onChanged: _editor.setFreezerDays,
        ),
      _SectionTitle(l10n.recipeIngredientsSection(recipeBasePortions)),
      _Hint(l10n.recipeIngredientsHelp, bottom: 12),
      for (final (position, row) in draft.ingredients.indexed)
        IngredientRow(
          key: ValueKey('recipe-ingredient-${row.key}'),
          row: row,
          position: position,
          count: draft.ingredients.length,
          controllers: _rowFor(row),
          errors: show ? errors.ingredients[row.key] : null,
          onNameChanged: (name) => _editor.updateIngredient(row.key, name: name),
          onQuantityChanged: (quantity) =>
              _editor.updateIngredient(row.key, quantity: quantity),
          onUnitChanged: (unit) => _setUnit(row.key, unit),
          onSectionChanged: (section) =>
              _editor.updateIngredient(row.key, section: section),
          onMove: (offset) => _editor.moveIngredient(row.key, offset),
          onRemove: () => _removeIngredient(row.key),
        ),
      if (draft.ingredients.length >= maxIngredients)
        _Hint(l10n.recipeIngredientsMax(maxIngredients), bottom: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          key: const ValueKey('recipe-ingredient-add'),
          onPressed: draft.ingredients.length >= maxIngredients
              ? null
              : _addIngredient,
          icon: const Icon(Icons.add),
          label: Text(l10n.recipeIngredientAdd),
        ),
      ),
      const SizedBox(height: 24),
      KeyedSubtree(
        key: _notesKey,
        child: TextField(
          key: const ValueKey('recipe-notes'),
          controller: _notes,
          minLines: 2,
          maxLines: 6,
          maxLength: maxRecipeNotesLength,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          onChanged: _editor.setNotes,
          decoration: InputDecoration(
            labelText: l10n.recipeNotesLabel,
            helperText: l10n.recipeNotesHelper,
            errorText: show
                ? _textError(l10n, errors.notes, maxRecipeNotesLength)
                : null,
          ),
        ),
      ),
      if (target is EditRecipe) ...[
        const Divider(height: 48),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('recipe-duplicate'),
              onPressed: () => unawaited(_duplicate()),
              icon: const Icon(Icons.copy_all_outlined),
              label: Text(l10n.recipeDuplicate),
            ),
            if (!inactive)
              OutlinedButton.icon(
                key: const ValueKey('recipe-deactivate'),
                onPressed: state.changingActive
                    ? null
                    : () => unawaited(_setActive(active: false)),
                icon: const Icon(Icons.visibility_off_outlined),
                label: Text(l10n.recipeDeactivate),
              ),
          ],
        ),
        if (!inactive) _Hint(l10n.recipeDeactivateHelp),
      ],
    ];

    return PopScope<Object?>(
      canPop: !state.dirty && !state.busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: ScaffoldMessenger(
        key: _messenger,
        child: Scaffold(
          appBar: AppBar(
            // Mientras traduce o guarda no se puede salir: el botón se ve
            // deshabilitado (el lector de pantalla lo dice).
            leading: (ModalRoute.of(context)?.impliesAppBarDismissal ?? false)
                ? IconButton(
                    key: const ValueKey('recipe-back'),
                    icon: const BackButtonIcon(),
                    tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                    onPressed: state.busy
                        ? null
                        : () => unawaited(Navigator.maybePop(context)),
                  )
                : null,
            title: Text(title),
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              // Todo construido (no perezoso): así se puede llevar a la vista
              // el primer campo con error aunque esté lejos.
              child: SingleChildScrollView(
                key: const ValueKey('recipe-editor'),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                // Mientras traduce no se puede tocar ni escribir nada (la
                // traducción pisaría lo nuevo); se puede seguir mirando.
                child: AbsorbPointer(
                  absorbing: state.translating,
                  child: ExcludeFocus(
                    excluding: state.translating,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: form,
                    ),
                  ),
                ),
              ),
            ),
          ),
          bottomNavigationBar: _SaveBar(
            saving: state.busy,
            translating: state.translating,
            preparingPhoto: state.preparingPhoto,
            onSave: _save,
          ),
        ),
      ),
    );
  }
}

/// «Salva», abajo y a lo ancho: a mano con el pulgar. Con el teclado abierto
/// queda justo arriba de él: Scaffold no sube la barra de abajo (solo achica
/// el cuerpo), así que el margen del teclado lo pone la barra misma. Sigue
/// siendo la barra de abajo para que los avisos salgan encima.
class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.saving,
    required this.translating,
    required this.preparingPhoto,
    required this.onSave,
  });

  final bool saving;

  /// Traduciendo: puede tardar, así que además de la ruedita lo dice.
  final bool translating;

  /// Se está eligiendo o preparando una foto: «Salva» espera (si no, el plato
  /// se guardaría sin ella).
  final bool preparingPhoto;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('recipe-save'),
                    onPressed: saving || preparingPhoto ? null : onSave,
                    child: switch ((saving, translating)) {
                      (_, true) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                l10n.recipeTranslating,
                                key: const ValueKey('recipe-translating'),
                              ),
                            ),
                          ),
                        ],
                      ),
                      // La ruedita sola no dice nada al lector de pantalla.
                      (true, _) => Semantics(
                        label: l10n.recipeSaving,
                        child: const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      _ => Text(l10n.actionSave),
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Una descripción de la web. Una sola línea (la base no acepta saltos: el
/// teclado ofrece «Siguiente» o «Listo», no un salto de línea), que se ve en
/// hasta tres. El contador avisa los 200 caracteres sin cortar lo escrito: si
/// se pasa, lo dice el error al guardar, como en los nombres.
///
/// El contador cuenta como la validación ([recipeTextLength]: el texto sin
/// espacios de más, por caracteres como la base), no como el de TextField
/// (lo escrito, por letras): con espacios dobles decía «205/200» en rojo y se
/// guardaba, y con una bandera, «200/200» y daba error. Por eso no hay
/// maxLength: el contador y el rojo de pasarse salen de acá.
class _DescriptionField extends StatelessWidget {
  const _DescriptionField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.error,
    required this.textInputAction,
    required this.onChanged,
    this.helper,
    this.focusNode,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;
  final String? error;

  /// Debajo del campo, a la izquierda del contador (la marca de la
  /// traducción automática).
  final Widget? helper;
  final TextInputAction textInputAction;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final material = MaterialLocalizations.of(context);
    const max = maxRecipeDescriptionLength;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final length = recipeTextLength(value.text);
          final tooLong = length > max;
          return TextField(
            key: fieldKey,
            controller: controller,
            focusNode: focusNode,
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.text,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: textInputAction,
            onChanged: onChanged,
            decoration: InputDecoration(
              labelText: label,
              helper: helper,
              // Pasada, en rojo como el contador de TextField, aunque todavía
              // no se haya intentado guardar.
              errorText: error ?? (tooLong ? '' : null),
              errorMaxLines: 2,
              counterText: '$length/$max',
              semanticCounterText: material.remainingTextFieldCharacterCount(
                (max - length).clamp(0, max),
              ),
              counterStyle: tooLong
                  ? theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    )
                  : null,
            ),
          );
        },
      ),
    );
  }
}

/// Número de días (heladera o freezer), con teclado numérico.
class _DaysField extends StatelessWidget {
  const _DaysField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.maxDigits,
    required this.error,
    required this.onChanged,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final int maxDigits;
  final String? error;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: 240,
        child: TextField(
          key: fieldKey,
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(maxDigits),
          ],
          textInputAction: TextInputAction.done,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            errorText: error,
            errorMaxLines: 2,
          ),
        ),
      ),
    );
  }
}

class _InactiveBanner extends StatelessWidget {
  const _InactiveBanner({required this.onReactivate});

  final VoidCallback? onReactivate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('recipe-inactive-banner'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.recipeInactiveBanner,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onTertiaryContainer,
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.tonal(
              key: const ValueKey('recipe-reactivate'),
              onPressed: onReactivate,
              child: Text(l10n.recipeReactivate),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {super.key, this.bottom = 0});

  final String text;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: 4, bottom: bottom),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Debajo de un campo en italiano o en inglés que llenó la traducción
/// automática y nadie tocó a mano.
class _AutoTranslatedMark extends StatelessWidget {
  const _AutoTranslatedMark({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.translate, size: 16, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            l10n.recipeAutoTranslated,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// Qué eligió Evelyn en el aviso de la traducción que falló.
enum _AfterTranslateFailure { retry, skip, write }

/// Enlace a un plato que no está en el catálogo.
class _RecipeNotFound extends StatelessWidget {
  const _RecipeNotFound();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.recipesTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.recipeNotFound,
                key: const ValueKey('recipe-not-found'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('recipe-back-to-list'),
                onPressed: () => context.go(AppRoutes.recipes),
                child: Text(l10n.recipeBackToList),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

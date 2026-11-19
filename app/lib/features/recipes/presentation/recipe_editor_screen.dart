// Editor de un plato del catálogo, a pantalla completa. Primero lo rápido:
// el nombre en italiano (el principal), los alérgenos, la dieta,
// la temporada y la descripción de la web (sin la italiana el plato no sale
// en el formulario de pedido); después lo opcional: nombres en español e
// inglés, conservación, ingredientes con su cantidad para 4 porciones y notas.
// «Salva» queda abajo, siempre a mano (con el teclado abierto, justo arriba de
// él). Un plato guardado se puede duplicar y desactivar (nunca se borra). Solo
// muestra providers: la lógica está en RecipeEditorController.
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
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/presentation/ingredient_row.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
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

  /// Los campos de cada fila de ingrediente, por su clave.
  final Map<int, IngredientRowControllers> _rows = {};

  /// Para llevar a la vista el primer campo con error.
  final GlobalKey _nameKey = GlobalKey();
  final GlobalKey _dietKey = GlobalKey();
  final GlobalKey _descriptionKey = GlobalKey();
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

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final l10n = AppLocalizations.of(context);
    final result = await _editor.save();
    if (!mounted) return;
    final state = _state;
    switch (result) {
      case RecipeSaveResult.saved:
        // La lista lo avisa (este editor se cierra).
        final saved = state.source;
        if (saved != null) {
          ref.read(recipeSavedNoticeProvider.notifier).post(saved);
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
      case RecipeSaveResult.busy:
        break;
    }
  }

  /// Lleva a la vista el primer campo con error, en el orden del formulario.
  void _revealFirstError(RecipeEditorState state) {
    final errors = state.errors;
    final firstRow = state.draft.ingredients
        .where((row) => errors.ingredients.containsKey(row.key))
        .firstOrNull;
    final key = switch (errors) {
      _ when errors.nameIt != null => _nameKey,
      _ when errors.dietConflicts.isNotEmpty => _dietKey,
      _
          when errors.descriptionIt != null ||
              errors.descriptionEs != null ||
              errors.descriptionEn != null =>
        _descriptionKey,
      _ when errors.nameEs != null || errors.nameEn != null => _translationsKey,
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
    if (_state.saving) return;
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
          key: const ValueKey('recipe-name-it'),
          controller: _nameIt,
          autofocus: target is! EditRecipe,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          onChanged: _editor.setNameIt,
          decoration: InputDecoration(
            labelText: l10n.recipeNameItLabel,
            helperText: nameTaken ? l10n.recipeNameTaken : l10n.recipeNameItHelper,
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
        key: _descriptionKey,
        child: _SectionTitle(l10n.recipeDescriptionSection),
      ),
      _Hint(l10n.recipeDescriptionHelp),
      _DescriptionField(
        fieldKey: const ValueKey('recipe-description-it'),
        controller: _descriptionIt,
        label: l10n.recipeDescriptionItLabel,
        error: show
            ? _textError(l10n, errors.descriptionIt, maxRecipeDescriptionLength)
            : null,
        textInputAction: TextInputAction.next,
        onChanged: _editor.setDescriptionIt,
      ),
      _DescriptionField(
        fieldKey: const ValueKey('recipe-description-es'),
        controller: _descriptionEs,
        label: l10n.recipeDescriptionEsLabel,
        error: show
            ? _textError(l10n, errors.descriptionEs, maxRecipeDescriptionLength)
            : null,
        textInputAction: TextInputAction.next,
        onChanged: _editor.setDescriptionEs,
      ),
      _DescriptionField(
        fieldKey: const ValueKey('recipe-description-en'),
        controller: _descriptionEn,
        label: l10n.recipeDescriptionEnLabel,
        error: show
            ? _textError(l10n, errors.descriptionEn, maxRecipeDescriptionLength)
            : null,
        textInputAction: TextInputAction.done,
        onChanged: _editor.setDescriptionEn,
      ),
      const Divider(height: 48),
      Semantics(
        header: true,
        child: Text(l10n.recipeOptionalSection, style: theme.textTheme.titleMedium),
      ),
      const SizedBox(height: 16),
      KeyedSubtree(
        key: _translationsKey,
        child: TextField(
          key: const ValueKey('recipe-name-es'),
          controller: _nameEs,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.next,
          onChanged: _editor.setNameEs,
          decoration: InputDecoration(
            labelText: l10n.recipeNameEsLabel,
            errorText: show
                ? _textError(l10n, errors.nameEs, maxRecipeNameLength)
                : null,
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('recipe-name-en'),
        controller: _nameEn,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        onChanged: _editor.setNameEn,
        decoration: InputDecoration(
          labelText: l10n.recipeNameEnLabel,
          errorText: show
              ? _textError(l10n, errors.nameEn, maxRecipeNameLength)
              : null,
        ),
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
      canPop: !state.dirty && !state.saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: ScaffoldMessenger(
        key: _messenger,
        child: Scaffold(
          appBar: AppBar(title: Text(title)),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              // Todo construido (no perezoso): así se puede llevar a la vista
              // el primer campo con error aunque esté lejos.
              child: SingleChildScrollView(
                key: const ValueKey('recipe-editor'),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: form,
                ),
              ),
            ),
          ),
          bottomNavigationBar: _SaveBar(saving: state.saving, onSave: _save),
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
  const _SaveBar({required this.saving, required this.onSave});

  final bool saving;
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
                    onPressed: saving ? null : onSave,
                    child: saving
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.actionSave),
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
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? error;
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
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.text,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: textInputAction,
            onChanged: onChanged,
            decoration: InputDecoration(
              labelText: label,
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
  const _Hint(this.text, {this.bottom = 0});

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

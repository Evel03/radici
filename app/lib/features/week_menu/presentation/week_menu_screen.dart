// Menú de una semana (`/sessioni/:id/menu`, SPEC 5.8 paso 4): arriba la
// clienta, «Semana k de N», el día con la llegada y las personas, y las
// alergias de la reserva resaltadas como en la ficha (nunca «sin alergias»
// sin datos). Después los platos en orden, cada uno con su foto, sus
// porciones (− y +), subir, bajar, quitar y, si choca con las alergias o la
// dieta de la reserva, la marca en rojo con el porqué; «Agregar platos» abre
// el selector del catálogo (con «Nuevo plato», que abre el editor de platos
// encima, sin ruta: no deja una entrada en el historial del navegador).
// Después la lista de compras por sección del súper, que sigue sola a los
// platos hasta que se cambia a mano (con «Rehacer la lista con los platos»;
// una lista guardada que ya no coincide con los platos lo dice sin culpar a
// nadie), y la nota para la clienta. La clienta recibe la nota tal como la
// escribe Evelyn y los nombres de la lista traducidos solos a su idioma
// (decisión del 22/11/2026): la pantalla dice cuál es ese idioma. «Guardar el
// menú» queda abajo; si algún plato choca, pide confirmarlo antes.
//
// Si otro teléfono guardó el menú en el medio, lo dice y ofrece cargar el
// guardado; si falla la red, lo escrito queda para reintentar. Si la sesión
// ya no admite menú, el editor queda a la vista pero bloqueado. Con cambios
// sin guardar, volver pregunta antes de descartarlos (en /gestione/, también
// el atrás del navegador: el onExit de la ruta, router.dart).
//
// Debajo de las alergias, el envío a la clienta (menu_send_status_view.dart):
// si ya salió, cuándo y por dónde, y lo que contestó la clienta (con su
// mensaje entero si pidió cambios), o que el menú cambió después de mandarlo.
// «Mandar», al lado de «Guardar el menú», abre la vista previa del mensaje
// (menu_send_screen.dart) con el menú guardado: con cambios sin guardar, pide
// guardarlos antes. Si al mandarlo resulta que otro teléfono guardó el menú,
// el editor carga lo guardado.
//
// Solo muestra providers: la lógica está en WeekMenuEditorController. Lleva
// datos de salud (las alergias): nada se loguea.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/application/recipe_editor_controller.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
import 'package:radici/features/recipes/presentation/recipe_photo_thumbnail.dart';
import 'package:radici/features/recipes/presentation/saved_recipe_snack_bar.dart';
import 'package:radici/features/requests/domain/chef_request.dart'
    show ClientLocale;
import 'package:radici/features/requests/presentation/inbox_screen.dart'
    show LoadErrorView;
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/features/sessions/presentation/session_widgets.dart';
import 'package:radici/features/week_menu/application/week_menu_editor_controller.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/features/week_menu/presentation/menu_dish_picker.dart';
import 'package:radici/features/week_menu/presentation/menu_send_screen.dart';
import 'package:radici/features/week_menu/presentation/menu_send_status_view.dart';
import 'package:radici/features/week_menu/presentation/shopping_item_dialog.dart';
import 'package:radici/features/week_menu/presentation/week_menu_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// «¿Descartar los cambios?» al salir del editor con cambios sin guardar
/// (también desde el onExit de la ruta). true si se eligió descartar.
Future<bool> confirmDiscardMenuChanges(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final discard = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('week-menu-discard-dialog'),
      title: Text(l10n.recipeDiscardTitle),
      content: Text(l10n.recipeDiscardBody),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          key: const ValueKey('week-menu-discard-keep'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.recipeDiscardKeep),
        ),
        FilledButton(
          key: const ValueKey('week-menu-discard-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.recipeDiscardConfirm),
        ),
      ],
    ),
  );
  return discard ?? false;
}

class WeekMenuScreen extends ConsumerWidget {
  const WeekMenuScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final editor = ref.watch(weekMenuEditorProvider(sessionId));
    Widget plain(Widget body) => Scaffold(
      appBar: AppBar(title: Text(l10n.weekMenuTitle)),
      body: body,
    );
    const loading = Center(child: CircularProgressIndicator());
    return editor.when(
      // Al volver a cargar lo guardado, el editor se rearma con sus campos.
      data: (state) => KeyedSubtree(
        key: ValueKey('week-menu-${state.generation}'),
        child: _WeekMenuEditor(sessionId: sessionId),
      ),
      error: (error, _) => plain(
        error is MenuFailure && error.kind == MenuFailureKind.sessionNotFound
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.sessionNotFound,
                    key: const ValueKey('week-menu-not-found'),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : LoadErrorView(
                message: l10n.weekMenuLoadFailed,
                onRetry: () {
                  if (ref.read(recipeCatalogProvider).hasError) {
                    ref.invalidate(recipeCatalogProvider);
                  }
                  ref
                    ..invalidate(sessionDetailProvider(sessionId))
                    ..invalidate(weekMenuEditorProvider(sessionId));
                },
              ),
      ),
      loading: () => plain(loading),
    );
  }
}

class _WeekMenuEditor extends ConsumerStatefulWidget {
  const _WeekMenuEditor({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_WeekMenuEditor> createState() => _WeekMenuEditorState();
}

class _WeekMenuEditorState extends ConsumerState<_WeekMenuEditor> {
  /// Avisos propios: quedan en el editor (con el de la app seguirían a la
  /// vista en la ficha al cerrarlo).
  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();

  late final TextEditingController _note;

  String get _sessionId => widget.sessionId;

  WeekMenuEditorController get _editor =>
      ref.read(weekMenuEditorProvider(_sessionId).notifier);

  WeekMenuEditorState? get _state =>
      ref.read(weekMenuEditorProvider(_sessionId)).value;

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(text: _state?.note ?? '');
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// Con VoiceOver o TalkBack el aviso no se va solo: se cierra con la X.
  bool get _persist => MediaQuery.accessibleNavigationOf(context);

  String get _language => Localizations.localeOf(context).languageCode;

  /// La ficha de ahora o, si ya no se puede leer, la que se cargó.
  SessionDetail? get _detail =>
      ref.read(sessionDetailProvider(_sessionId)).value ?? _state?.detail;

  /// El idioma de la clienta, como se muestra («Italiano»).
  String get _clientLanguage {
    final session = _detail?.session;
    return AppLocalizations.of(context)
        .language(session?.locale ?? ClientLocale.it);
  }

  void _show(SnackBar snackBar) {
    final messenger = _messenger.currentState;
    if (messenger == null) return;
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(snackBar);
  }

  void _showError(String message, {VoidCallback? retry}) => _show(
    SnackBar(
      content: Text(message),
      duration: errorSnackBarDuration,
      persist: _persist,
      showCloseIcon: _persist,
      action: retry == null
          ? null
          : SnackBarAction(
              label: AppLocalizations.of(context).actionRetry,
              onPressed: retry,
            ),
    ),
  );

  // ------------------------------------------------------------------
  // Platos
  // ------------------------------------------------------------------

  Future<void> _pickDishes() async {
    final state = _state;
    if (state == null) return;
    final choice = await showMenuDishPicker(
      context,
      chosen: {for (final dish in state.dishes) dish.recipe.id},
      restrictions: ref.read(weekMenuRestrictionsProvider(_sessionId)),
      room: maxMenuDishes - state.dishes.length,
    );
    if (!mounted) return;
    switch (choice) {
      case AddPickedDishes(:final recipes):
        _editor.addDishes(recipes);
      case CreateNewDish(:final picked):
        // Lo marcado entra igual, aunque después no se guarde el plato nuevo.
        _editor.addDishes(picked);
        await _newDish();
      case null:
        break;
    }
  }

  /// Abre el editor de platos encima, sin ruta: no queda una entrada del
  /// historial del navegador entre el menú y el editor (el atrás del
  /// navegador sale del menú, que pregunta si hay cambios). El plato que se
  /// guarde ahí entra al menú, también si la foto falló (el editor vuelve con
  /// él igual). Guardado sin traducir, el aviso dura como en la lista de
  /// platos y, con VoiceOver o TalkBack, se cierra con la X.
  Future<void> _newDish() async {
    final l10n = AppLocalizations.of(context);
    final notice = await Navigator.of(context).push<SavedRecipeNotice>(
      MaterialPageRoute<SavedRecipeNotice>(
        builder: (_) => const RecipeEditorScreen(
          target: RecipeEditorTarget.create(),
          returnsSaved: true,
        ),
      ),
    );
    if (notice == null || !mounted) return;
    final added = _editor.addDishes([notice.recipe]);
    final name = recipeNameIn(notice.recipe, _language);
    final because = notice.untranslatedBecause;
    _show(
      savedRecipeSnackBar(
        context,
        message: added == 0
            ? l10n.weekMenuDishCreatedMenuFull(name)
            : switch (because) {
                null => l10n.weekMenuDishCreated(name),
                TranslationFailureKind.notConfigured =>
                  l10n.weekMenuDishCreatedUntranslated(name),
                _ => l10n.weekMenuDishCreatedUntranslatable(name),
              },
        untranslated: because != null,
      ),
    );
  }

  void _removeDish(String recipeId) {
    final l10n = AppLocalizations.of(context);
    final removed = _editor.removeDish(recipeId);
    if (removed == null) return;
    _show(
      SnackBar(
        content: Text(l10n.weekMenuDishRemoved),
        duration: undoSnackBarDuration,
        persist: _persist,
        showCloseIcon: _persist,
        action: SnackBarAction(
          label: l10n.actionUndo,
          onPressed: () => _editor.restoreDish(removed),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Lista
  // ------------------------------------------------------------------

  Future<void> _editItem(ShoppingRow row) async {
    final item = await showShoppingItemDialog(
      context,
      clientLanguage: _clientLanguage,
      initial: row.item,
    );
    if (item == null || item == row.item || !mounted) return;
    _editor.updateItem(row.key, item);
  }

  Future<void> _addItem() async {
    final item = await showShoppingItemDialog(
      context,
      clientLanguage: _clientLanguage,
    );
    if (item == null || !mounted) return;
    _editor.addItem(item);
  }

  void _removeItem(ShoppingRow row) {
    final l10n = AppLocalizations.of(context);
    final removed = _editor.removeItem(row.key);
    if (removed == null) return;
    _show(
      SnackBar(
        content: Text(l10n.weekMenuItemRemoved),
        duration: undoSnackBarDuration,
        persist: _persist,
        showCloseIcon: _persist,
        action: SnackBarAction(
          label: l10n.actionUndo,
          onPressed: () => _editor.restoreItem(removed),
        ),
      ),
    );
  }

  Future<void> _rebuildList() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('week-menu-rebuild-dialog'),
        title: Text(l10n.weekMenuListRebuildTitle),
        content: Text(l10n.weekMenuListRebuildBody),
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(
            key: const ValueKey('week-menu-rebuild-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('week-menu-rebuild-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.weekMenuListRebuildConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _editor.rebuildList();
  }

  // ------------------------------------------------------------------
  // Guardar y salir
  // ------------------------------------------------------------------

  /// Guarda. Si algún plato choca con la reserva, primero pide confirmarlo
  /// (queda registrado: allergens_confirmed). true si quedó guardado.
  Future<bool> _save() async {
    FocusScope.of(context).unfocus();
    // El aviso de antes (un «Deshacer») no sigue a mano mientras guarda.
    _messenger.currentState?.removeCurrentSnackBar();
    final l10n = AppLocalizations.of(context);
    final state = _state;
    if (state == null || !state.canSave) return false;
    final conflicts = ref.read(weekMenuConflictsProvider(_sessionId));
    var confirmed = false;
    if (conflicts.isNotEmpty) {
      confirmed = await _confirmConflicts(state, conflicts);
      if (!confirmed || !mounted) return false;
    }
    final result = await _editor.save(allergensConfirmed: confirmed);
    if (!mounted) return result == WeekMenuSaveResult.saved;
    switch (result) {
      case WeekMenuSaveResult.saved:
        _show(SnackBar(content: Text(l10n.weekMenuSaved)));
      case WeekMenuSaveResult.invalid:
        _showError(l10n.recipeTextTooLong(maxMenuNoteLength));
      case WeekMenuSaveResult.failed:
        await _saveFailed();
      case WeekMenuSaveResult.busy:
        break;
    }
    return result == WeekMenuSaveResult.saved;
  }

  /// «Mandar»: la vista previa del mensaje con el menú guardado. Con cambios
  /// sin guardar (o un menú que nunca se guardó), primero pide guardarlo. Si
  /// el menú cambió en otro teléfono, al volver carga lo guardado (no hay
  /// nada sin guardar que perder).
  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    _messenger.currentState?.removeCurrentSnackBar();
    final l10n = AppLocalizations.of(context);
    final state = _state;
    if (state == null || !state.canSend) return;
    if (state.needsSaveBeforeSend) {
      if (state.noteTooLong) {
        _showError(l10n.recipeTextTooLong(maxMenuNoteLength));
        return;
      }
      if (!await _confirmSaveBeforeSend() || !mounted) return;
      if (!await _save() || !mounted) return;
    }
    final saved = _state;
    final version = saved?.version;
    if (saved == null || version == null || saved.dirty) return;
    final exit = await showMenuSendScreen(
      context,
      sessionId: _sessionId,
      menuVersion: version,
      fromEditor: true,
    );
    if (exit != MenuSendExit.menuChanged || !mounted) return;
    final message = l10n.weekMenuReloadFailed;
    // Si carga, el editor se rearma (esta pantalla se reemplaza).
    final loaded = await _editor.reload();
    if (!loaded && mounted) _showError(message);
  }

  /// «¿Guardar antes de mandar?»: la clienta recibe el menú guardado. true
  /// si eligió guardar.
  Future<bool> _confirmSaveBeforeSend() async {
    final l10n = AppLocalizations.of(context);
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('week-menu-save-first-dialog'),
        title: Text(l10n.menuSendSaveFirstTitle),
        content: Text(l10n.menuSendSaveFirstBody),
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(
            key: const ValueKey('week-menu-save-first-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('week-menu-save-first-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.menuSendSaveFirstConfirm),
          ),
        ],
      ),
    );
    return save ?? false;
  }

  Future<bool> _confirmConflicts(
    WeekMenuEditorState state,
    Map<String, DishConflict> conflicts,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          key: const ValueKey('week-menu-conflicts-dialog'),
          scrollable: true,
          title: Text(l10n.weekMenuConflictsTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.weekMenuConflictsBody),
              for (final dish in state.dishes)
                if (conflicts[dish.recipe.id] case final conflict?)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExcludeSemantics(
                          child: Icon(
                            Icons.warning_amber_rounded,
                            size: 20,
                            color: theme.colorScheme.error,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.weekMenuConflictLine(
                              recipeNameIn(dish.recipe, _language),
                              l10n.dishConflictText(conflict),
                            ),
                            key: ValueKey(
                              'week-menu-conflicts-${dish.recipe.id}',
                            ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
          actionsOverflowButtonSpacing: 8,
          actions: [
            TextButton(
              key: const ValueKey('week-menu-conflicts-review'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.weekMenuConflictsReview),
            ),
            FilledButton(
              key: const ValueKey('week-menu-conflicts-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.weekMenuConflictsConfirm),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  /// Dice por qué no se guardó. Lo escrito queda en la pantalla.
  Future<void> _saveFailed() async {
    final l10n = AppLocalizations.of(context);
    final state = _state;
    final failure = state?.saveError;
    if (state == null || failure == null) return;
    switch (failure.kind) {
      case MenuFailureKind.changed:
        await _menuChanged();
      case MenuFailureKind.unavailable:
        _showError(
          l10n.weekMenuErrorUnavailable,
          retry: () => unawaited(_save()),
        );
      case MenuFailureKind.notEditable:
        _showError(l10n.weekMenuErrorNotEditable);
      case MenuFailureKind.sessionNotFound:
        _showError(l10n.weekMenuErrorSessionNotFound);
      case MenuFailureKind.recipeNotFound:
        final index = failure.dishIndex;
        _showError(
          index != null && index >= 0 && index < state.dishes.length
              ? l10n.weekMenuErrorRecipeNotFound(
                  recipeNameIn(state.dishes[index].recipe, _language),
                )
              : l10n.weekMenuErrorRecipeNotFoundUnknown,
        );
      case MenuFailureKind.invalid:
        _showError(l10n.weekMenuErrorInvalid);
      case MenuFailureKind.forbidden:
        _showError(l10n.weekMenuErrorForbidden);
    }
  }

  /// Otro teléfono guardó el menú en el medio: cargar lo guardado (se pierde
  /// lo cambiado) o seguir viendo lo propio.
  Future<void> _menuChanged() async {
    final l10n = AppLocalizations.of(context);
    final reload = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('week-menu-changed-dialog'),
        scrollable: true,
        title: Text(l10n.weekMenuChangedTitle),
        content: Text(l10n.weekMenuChangedBody),
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(
            key: const ValueKey('week-menu-changed-keep'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.weekMenuChangedKeep),
          ),
          FilledButton(
            key: const ValueKey('week-menu-changed-reload'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.weekMenuChangedReload),
          ),
        ],
      ),
    );
    if (reload != true || !mounted) return;
    final message = l10n.weekMenuReloadFailed;
    // Si carga, el editor se rearma (esta pantalla se reemplaza).
    final loaded = await _editor.reload();
    if (!loaded && mounted) _showError(message);
  }

  /// Volver con cambios sin guardar: pregunta antes de descartarlos.
  Future<void> _confirmLeave() async {
    if (_state?.busy ?? true) return;
    if (!await confirmDiscardMenuChanges(context) || !mounted) return;
    _editor.allowLeave();
    Navigator.of(context).pop();
  }

  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(weekMenuEditorProvider(_sessionId)).value;
    if (state == null) return const SizedBox.shrink();
    // La de ahora o, si la sesión ya no se puede leer, la que se cargó.
    final detail =
        ref.watch(sessionDetailProvider(_sessionId)).value ?? state.detail;
    final conflicts = ref.watch(weekMenuConflictsProvider(_sessionId));
    final session = detail.session;
    final enabled = !state.locked;

    return PopScope<Object?>(
      // Bloqueado no hay nada que guardar: sale sin preguntar.
      canPop: state.leaving || state.locked || (!state.dirty && !state.busy),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: ScaffoldMessenger(
        key: _messenger,
        child: Scaffold(
          appBar: AppBar(
            // Mientras guarda no se puede salir: el botón se ve deshabilitado.
            leading: (ModalRoute.of(context)?.impliesAppBarDismissal ?? false)
                ? IconButton(
                    key: const ValueKey('week-menu-back'),
                    icon: const BackButtonIcon(),
                    tooltip: MaterialLocalizations.of(context)
                        .backButtonTooltip,
                    onPressed: state.busy
                        ? null
                        : () => unawaited(Navigator.maybePop(context)),
                  )
                : null,
            title: Text(l10n.weekMenuTitle),
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: sessionMaxContentWidth,
              ),
              child: SingleChildScrollView(
                key: const ValueKey('week-menu-editor'),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                // Mientras guarda o vuelve a leer, nada se puede tocar.
                child: AbsorbPointer(
                  absorbing: state.busy,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Header(detail: detail),
                      if (state.blockedBy case final kind?)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _Banner(
                            key: const ValueKey('week-menu-blocked'),
                            text: kind == MenuFailureKind.notEditable
                                ? l10n.weekMenuErrorNotEditable
                                : l10n.weekMenuErrorSessionNotFound,
                          ),
                        )
                      else if (state.readOnly)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _Banner(
                            key: const ValueKey('week-menu-read-only'),
                            text: l10n.weekMenuReadOnly(
                              l10n.sessionStatus(session.status),
                            ),
                          ),
                        ),
                      SessionAllergies(session: session),
                      if (session.requestId != null) ..._sendStatus(state),
                      ..._dishes(state, conflicts, enabled: enabled),
                      ..._list(state, enabled: enabled),
                      ..._noteField(state, session),
                    ],
                  ),
                ),
              ),
            ),
          ),
          bottomNavigationBar: state.locked
              ? null
              : _SaveBar(
                  saving: state.saving,
                  onSave: state.canSave ? () => unawaited(_save()) : null,
                  // Sin pedido no hay reserva que mostrar en el link.
                  showSend: isMenuSendable(session),
                  onSend: state.canSend ? () => unawaited(_send()) : null,
                ),
        ),
      ),
    );
  }

  /// El envío a la clienta: si ya salió y qué contestó, o que el menú cambió
  /// después de mandarlo. Nada mientras no hay menú guardado ni envío.
  List<Widget> _sendStatus(WeekMenuEditorState state) {
    final l10n = AppLocalizations.of(context);
    final everSent = ref.watch(
      latestMenuSendProvider(_sessionId).select((send) => send.value != null),
    );
    if (state.version == null && !everSent) return const [];
    return [
      SessionSection(l10n.menuSendSection),
      SessionMenuSendStatus(
        sessionId: _sessionId,
        savedVersion: state.version,
        keyPrefix: 'week-menu-status',
      ),
    ];
  }

  List<Widget> _dishes(
    WeekMenuEditorState state,
    Map<String, DishConflict> conflicts, {
    required bool enabled,
  }) {
    final l10n = AppLocalizations.of(context);
    final dishes = state.dishes;
    return [
      SessionSection(l10n.weekMenuDishesSection),
      if (state.showsWishesHint)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _Hint(
            l10n.weekMenuFromWishes,
            textKey: const ValueKey('week-menu-from-wishes'),
          ),
        ),
      if (dishes.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: MergeSemantics(
            child: Text(
              l10n.weekMenuNoDishes,
              key: const ValueKey('week-menu-no-dishes'),
            ),
          ),
        ),
      for (final (index, dish) in dishes.indexed)
        _DishCard(
          key: ValueKey('week-menu-dish-${dish.recipe.id}'),
          dish: dish,
          name: recipeNameIn(dish.recipe, _language),
          conflict: conflicts[dish.recipe.id],
          index: index,
          count: dishes.length,
          enabled: enabled,
          onPortions: (portions) =>
              _editor.setPortions(dish.recipe.id, portions),
          onMove: (offset) => _editor.moveDish(dish.recipe.id, offset),
          onRemove: () => _removeDish(dish.recipe.id),
        ),
      if (!state.canAddDish)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _Hint(l10n.weekMenuMaxDishes(maxMenuDishes)),
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          key: const ValueKey('week-menu-add-dish'),
          onPressed: enabled && state.canAddDish
              ? () => unawaited(_pickDishes())
              : null,
          icon: const Icon(Icons.add),
          label: Text(l10n.weekMenuAddDish),
        ),
      ),
    ];
  }

  List<Widget> _list(WeekMenuEditorState state, {required bool enabled}) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = ShoppingFormats(context);
    final rows = state.orderedItems;
    final withoutIngredients = state.dishesWithoutIngredients;
    return [
      SessionSection(l10n.weekMenuListSection),
      _Hint(switch (state.listMode) {
        ShoppingListMode.automatic => l10n.weekMenuListAuto,
        ShoppingListMode.manual => l10n.weekMenuListManual,
        ShoppingListMode.stale => l10n.weekMenuListStale,
      }, textKey: const ValueKey('week-menu-list-mode')),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: _Hint(
          l10n.weekMenuListTranslated(_clientLanguage),
          textKey: const ValueKey('week-menu-list-translated'),
        ),
      ),
      if (state.listMode != ShoppingListMode.automatic && enabled)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('week-menu-rebuild'),
            onPressed: () => unawaited(_rebuildList()),
            icon: const Icon(Icons.refresh),
            label: Text(l10n.weekMenuListRebuild),
          ),
        ),
      if (state.listTruncated)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _Banner(
            key: const ValueKey('week-menu-list-truncated'),
            text: l10n.weekMenuListTruncated(maxShoppingItems),
          ),
        ),
      if (withoutIngredients.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _Hint(
            l10n.weekMenuListNoIngredients(
              [for (final r in withoutIngredients) recipeNameIn(r, _language)]
                  .join(', '),
            ),
            textKey: const ValueKey('week-menu-no-ingredients'),
          ),
        ),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: MergeSemantics(
            child: Text(
              l10n.weekMenuListEmpty,
              key: const ValueKey('week-menu-list-empty'),
            ),
          ),
        ),
      for (final section in ShoppingSection.values)
        if (rows.where((row) => row.item.section == section).toList()
            case final inSection when inSection.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: MergeSemantics(
              child: Text(
                l10n.shoppingSection(section),
                key: ValueKey('week-menu-section-${section.dbValue}'),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          for (final row in inSection)
            _ItemTile(
              key: ValueKey('week-menu-item-${row.key}'),
              row: row,
              amount: formats.amount(row.item.amount),
              enabled: enabled,
              onEdit: () => unawaited(_editItem(row)),
              onRemove: () => _removeItem(row),
            ),
        ],
      if (!state.canAddItem)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _Hint(l10n.weekMenuItemMax(maxShoppingItems)),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const ValueKey('week-menu-add-item'),
            onPressed: enabled && state.canAddItem
                ? () => unawaited(_addItem())
                : null,
            icon: const Icon(Icons.add),
            label: Text(l10n.weekMenuItemAdd),
          ),
        ),
      ),
    ];
  }

  /// La nota le llega a la clienta tal como la escribe Evelyn: la ayuda dice
  /// en qué idioma escribirla y el ejemplo está en ese idioma.
  List<Widget> _noteField(WeekMenuEditorState state, CookingSession session) {
    final l10n = AppLocalizations.of(context);
    final client = lookupAppLocalizations(Locale(session.locale.name));
    final theme = Theme.of(context);
    final material = MaterialLocalizations.of(context);
    const max = maxMenuNoteLength;
    return [
      SessionSection(l10n.weekMenuNoteSection),
      // El contador cuenta como la base (por caracteres, sin espacios al
      // borde): por eso no hay maxLength, como en las descripciones de un
      // plato.
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _note,
        builder: (context, value, _) {
          final length = menuNoteLength(value.text);
          final tooLong = length > max;
          return TextField(
            key: const ValueKey('week-menu-note'),
            controller: _note,
            readOnly: state.locked,
            autofillHints: null,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            onChanged: _editor.setNote,
            // 16 px o más: con menos, iOS agranda la página al enfocar.
            style: theme.textTheme.bodyLarge,
            decoration: InputDecoration(
              labelText: l10n.weekMenuNoteLabel,
              hintText: client.weekMenuNoteHint,
              alignLabelWithHint: true,
              helperText: l10n.weekMenuNoteHelper(
                l10n.language(session.locale),
              ),
              helperMaxLines: 3,
              errorText: tooLong ? l10n.recipeTextTooLong(max) : null,
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
    ];
  }
}

/// La clienta, «Semana k de N», el día con la llegada y las personas. Cada
/// renglón es un nodo propio del lector de pantalla.
class _Header extends StatelessWidget {
  const _Header({required this.detail});

  final SessionDetail detail;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final session = detail.session;
    final position = detail.position;
    final people = session.people;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MergeSemantics(
          child: Text(
            session.displayName,
            key: const ValueKey('week-menu-client'),
            style: theme.textTheme.titleLarge,
          ),
        ),
        if (position != null)
          MergeSemantics(
            child: Text(
              l10n.sessionWeekOf(position.week, position.weeks),
              key: const ValueKey('week-menu-week'),
              style: theme.textTheme.titleSmall,
            ),
          ),
        const SizedBox(height: 4),
        MergeSemantics(
          child: Text(
            formats.longDate(session.date),
            key: const ValueKey('week-menu-date'),
            style: theme.textTheme.bodyLarge,
          ),
        ),
        MergeSemantics(
          child: Text(
            l10n.sessionTimesLine(session),
            key: const ValueKey('week-menu-times'),
            style: theme.textTheme.bodyLarge,
          ),
        ),
        if (people != null)
          MergeSemantics(
            child: Text(
              l10n.requestPeopleCount(people),
              key: const ValueKey('week-menu-people'),
              style: theme.textTheme.bodyLarge,
            ),
          ),
      ],
    );
  }
}

/// Un plato del menú: la foto, el nombre, si está desactivado, el choque con
/// la reserva (en rojo), las porciones con − y +, subir, bajar y quitar.
class _DishCard extends StatelessWidget {
  const _DishCard({
    super.key,
    required this.dish,
    required this.name,
    required this.conflict,
    required this.index,
    required this.count,
    required this.enabled,
    required this.onPortions,
    required this.onMove,
    required this.onRemove,
  });

  final WeekMenuDish dish;
  final String name;
  final DishConflict? conflict;

  /// Lugar del plato (desde 0) y cuántos hay: el primero no sube y el último
  /// no baja.
  final int index;
  final int count;
  final bool enabled;
  final ValueChanged<int> onPortions;

  /// -1 sube el plato y 1 lo baja.
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final id = dish.recipe.id;
    final photoId = dish.recipe.photoId;
    final portions = dish.portions;
    final conflict = this.conflict;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: conflict == null ? colors.outlineVariant : colors.error,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (photoId != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: 4, end: 12),
                  child: RecipePhotoThumbnail(
                    key: ValueKey('week-menu-dish-photo-$id'),
                    recipeId: id,
                    photoId: photoId,
                    size: 48,
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: MergeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          key: ValueKey('week-menu-dish-name-$id'),
                          style: theme.textTheme.titleMedium,
                        ),
                        if (!dish.recipe.active)
                          Text(
                            l10n.recipeInactive,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        if (conflict != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ExcludeSemantics(
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    size: 18,
                                    color: colors.error,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    l10n.dishConflictText(conflict),
                                    key: ValueKey(
                                      'week-menu-dish-conflict-$id',
                                    ),
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.error,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: ValueKey('week-menu-dish-remove-$id'),
                tooltip: l10n.weekMenuDishRemove(name),
                icon: const Icon(Icons.delete_outline),
                onPressed: enabled ? onRemove : null,
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton.filledTonal(
                    key: ValueKey('week-menu-dish-less-$id'),
                    tooltip: l10n.weekMenuPortionsLess(name),
                    onPressed: enabled && portions > 1
                        ? () => onPortions(portions - 1)
                        : null,
                    icon: const Icon(Icons.remove),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 96),
                    child: Text(
                      l10n.weekMenuPortions(portions),
                      key: ValueKey('week-menu-dish-portions-$id'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton.filledTonal(
                    key: ValueKey('week-menu-dish-more-$id'),
                    tooltip: l10n.weekMenuPortionsMore(name),
                    onPressed: enabled && portions < maxDishPortions
                        ? () => onPortions(portions + 1)
                        : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: ValueKey('week-menu-dish-up-$id'),
                    tooltip: l10n.weekMenuDishUp(name),
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: enabled && index > 0 ? () => onMove(-1) : null,
                  ),
                  IconButton(
                    key: ValueKey('week-menu-dish-down-$id'),
                    tooltip: l10n.weekMenuDishDown(name),
                    icon: const Icon(Icons.arrow_downward),
                    onPressed: enabled && index < count - 1
                        ? () => onMove(1)
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Un renglón de la lista: qué y cuánto; tocarlo lo cambia.
class _ItemTile extends StatelessWidget {
  const _ItemTile({
    super.key,
    required this.row,
    required this.amount,
    required this.enabled,
    required this.onEdit,
    required this.onRemove,
  });

  final ShoppingRow row;
  final String amount;
  final bool enabled;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = row.item.name;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: enabled ? onEdit : null,
      title: Text(name),
      subtitle: Text(amount, key: ValueKey('week-menu-item-amount-${row.key}')),
      trailing: enabled
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: ValueKey('week-menu-item-edit-${row.key}'),
                  tooltip: l10n.weekMenuItemEdit(name),
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: onEdit,
                ),
                IconButton(
                  key: ValueKey('week-menu-item-remove-${row.key}'),
                  tooltip: l10n.weekMenuItemRemove(name),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onRemove,
                ),
              ],
            )
          : null,
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.textKey});

  final String text;

  /// La del `Text` (los tests lo leen por ahí).
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Text(
        text,
        key: textKey,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Un aviso resaltado (fondo terciario).
class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: MergeSemantics(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onTertiaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// «Guardar el menú» y «Mandar», abajo y a lo ancho: a mano con el pulgar.
/// Con el teclado abierto quedan justo arriba de él (como en el editor de
/// platos).
class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.saving,
    required this.onSave,
    required this.showSend,
    required this.onSend,
  });

  final bool saving;

  /// null: no hay nada para guardar (o no se puede).
  final VoidCallback? onSave;

  /// La sesión se le puede mandar a la clienta: va «Mandar» al lado.
  final bool showSend;

  /// null: no se puede mandar ahora (sin platos o guardando).
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final save = FilledButton(
      key: const ValueKey('week-menu-save'),
      onPressed: saving ? null : onSave,
      child: saving
          // La ruedita sola no dice nada al lector de pantalla.
          ? Semantics(
              label: l10n.recipeSaving,
              child: const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Text(l10n.weekMenuSave),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: sessionMaxContentWidth,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: showSend
                      ? Row(
                          children: [
                            Expanded(child: save),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.tonalIcon(
                                key: const ValueKey('week-menu-send'),
                                onPressed: saving ? null : onSend,
                                icon: const Icon(Icons.send_outlined),
                                label: Text(l10n.menuSendShort),
                              ),
                            ),
                          ],
                        )
                      : save,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

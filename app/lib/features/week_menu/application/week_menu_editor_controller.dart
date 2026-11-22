// Editor del menú de una semana (SPEC 5.8, paso 4): los platos con sus
// porciones, la lista de compras y la nota para la clienta, y el guardado
// entero con save_session_menu.
//
// La lista sigue sola a los platos mientras Evelyn no la toque: cada cambio de
// platos o porciones la rehace (buildShoppingList). En cuanto cambia, quita o
// agrega un renglón queda a mano, y «Rehacer la lista con los platos» la
// vuelve a armar; «Deshacer» un renglón quitado de una lista que seguía a los
// platos la deja siguiéndolos. Al abrir un menú guardado, sigue a los platos
// si lo guardado es justo la lista que sale de esos platos. Si no, no se sabe
// por qué (la cambió ella o cambió una receta del catálogo después): la lista
// guardada queda, con un aviso neutro que ofrece rehacerla. La base no guarda
// esa marca.
//
// La semana 1 sin menú guardado empieza con los platos que eligió la clienta
// en la web (requests.wishes), los que siguen en el catálogo y activos, sin
// guardar todavía.
//
// Al guardar se manda la versión cargada: si otro teléfono guardó en el medio,
// la base no escribe nada (menu_changed) y lo escrito queda en la pantalla.
// Antes de decir eso, se mira si lo guardado es un guardado propio: lo mismo
// que se manda (un reintento cuya primera respuesta se perdió), o el último
// guardado que se quedó sin respuesta, con la versión siguiente a la suya
// (después Evelyn siguió editando): en ese caso se reenvía lo de ahora con la
// versión nueva. Si falla por la red, también queda lo escrito. Si la sesión
// ya no admite menú (cancelada, cocinada o cobrada) o ya no existe, el editor
// queda bloqueado, con lo escrito a la vista, y la ficha se vuelve a leer.
// Nada se loguea: la nota es para la clienta.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/shopping_list.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

part 'week_menu_editor_controller.freezed.dart';

/// Un renglón de la lista mientras se edita: [key] lo identifica (sus botones
/// lo siguen aunque cambie de sección).
typedef ShoppingRow = ({int key, ShoppingItem item});

/// Un plato quitado y dónde estaba, para «Deshacer».
typedef RemovedDish = ({WeekMenuDish dish, int index});

/// Un renglón quitado, para «Deshacer»: dónde estaba, cómo estaba la lista
/// antes (a mano o con el aviso de que no coincidía con los platos) y la
/// revisión de la lista justo después de quitarlo ([WeekMenuEditorState.
/// listRevision]): si la lista cambió después, ya no se deshace.
typedef RemovedShoppingRow = ({
  ShoppingRow row,
  int index,
  bool wasManual,
  bool wasStale,
  int revision,
});

/// Un plato del menú, para comparar: la receta y sus porciones.
typedef MenuDishRef = ({String recipeId, int portions});

/// Qué dice la pantalla de la lista.
enum ShoppingListMode {
  /// Sigue sola a los platos.
  automatic,

  /// Evelyn la cambió en esta pantalla: ya no sigue a los platos.
  manual,

  /// Al abrir, la lista guardada no es la que sale hoy de los platos: la
  /// cambió ella o cambió una receta después. No sigue a los platos.
  stale,
}

/// Lo que cuenta para saber si hay cambios sin guardar: los platos con sus
/// porciones, la lista en el orden en que se guarda y la nota normalizada.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class WeekMenuContent with _$WeekMenuContent {
  const factory WeekMenuContent({
    @Default(<MenuDishRef>[]) List<MenuDishRef> dishes,
    @Default(<ShoppingItem>[]) List<ShoppingItem> items,
    String? note,
  }) = _WeekMenuContent;

  const WeekMenuContent._();

  /// Lo que se manda en [menu].
  factory WeekMenuContent.of(WeekMenuSave menu) => WeekMenuContent(
    dishes: [
      for (final dish in menu.dishes)
        (recipeId: dish.recipe.id, portions: dish.portions),
    ],
    items: menu.items,
    note: menu.note,
  );

  @override
  String toString() => 'WeekMenuContent(${dishes.length}, ${items.length})';
}

@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class WeekMenuEditorState with _$WeekMenuEditorState {
  const factory WeekMenuEditorState({
    required String sessionId,

    /// La ficha de la sesión como estaba al cargar: la pantalla la usa si
    /// después la sesión ya no se puede leer (por ejemplo, la borraron).
    required SessionDetail detail,

    /// La versión guardada que se cargó (null = todavía no hay menú).
    int? version,
    @Default(<WeekMenuDish>[]) List<WeekMenuDish> dishes,
    @Default(<ShoppingRow>[]) List<ShoppingRow> items,

    /// La lista no sigue a los platos (se cambió a mano, o no coincidía al
    /// abrir).
    @Default(false) bool manualList,

    /// Al abrir, la lista guardada no era la que sale de los platos. Se apaga
    /// en cuanto Evelyn cambia la lista o la rehace.
    @Default(false) bool listStale,

    /// La lista que sale de los platos tenía más de [maxShoppingItems]
    /// renglones: quedaron los primeros.
    @Default(false) bool listTruncated,

    /// Sube con cada cambio de la lista (también al rehacerla): «Deshacer» un
    /// renglón solo vale si la lista no cambió después.
    @Default(0) int listRevision,

    /// Lo escrito en la nota, tal cual.
    @Default('') String note,

    /// Lo guardado (o, en una semana 1 sin menú, los platos que eligió la
    /// clienta): sin cambios, no hay nada que guardar.
    @Default(WeekMenuContent()) WeekMenuContent initial,

    /// Porciones de un plato que se agrega ([defaultDishPortions]).
    @Default(1) int defaultPortions,

    /// El menú empezó con los platos que eligió la clienta en la web y
    /// todavía no se guardó.
    @Default(false) bool fromWishes,

    /// Los platos que eligió la clienta con que empezó el menú.
    @Default(<String>[]) List<String> wishIds,

    /// La sesión ya no admitía cambios de menú al abrir (cancelada, cocinada
    /// o cobrada).
    @Default(false) bool readOnly,

    /// El servidor dijo, al guardar, que la sesión ya no admite menú
    /// (notEditable) o ya no existe (sessionNotFound): nada más se puede
    /// cambiar ni guardar. null si no.
    MenuFailureKind? blockedBy,
    @Default(false) bool saving,

    /// Volviendo a leer lo guardado (después de menu_changed).
    @Default(false) bool reloading,

    /// Por qué falló el último guardado (null si no falló).
    MenuFailure? saveError,

    /// Evelyn eligió descartar los cambios: la pantalla ya puede cerrarse.
    @Default(false) bool leaving,

    /// Sube cada vez que se vuelve a cargar lo guardado: la pantalla rearma
    /// sus campos.
    @Default(0) int generation,
  }) = _WeekMenuEditorState;

  const WeekMenuEditorState._();

  /// Los renglones por sección, en el orden del súper: así se muestran y se
  /// guardan.
  List<ShoppingRow> get orderedItems =>
      sortedBySection(items, (row) => row.item.section);

  WeekMenuContent get content => WeekMenuContent(
    dishes: [
      for (final dish in dishes)
        (recipeId: dish.recipe.id, portions: dish.portions),
    ],
    items: [for (final row in orderedItems) row.item],
    note: normalizeMenuNote(note),
  );

  /// Hay cambios sin guardar.
  bool get dirty => content != initial;

  /// Guardando o volviendo a leer: nada se puede cambiar.
  bool get busy => saving || reloading;

  /// La sesión no admite cambios de menú (desde que se abrió, o porque lo
  /// dijo el servidor al guardar): se ve, pero no se cambia.
  bool get locked => readOnly || blockedBy != null;

  bool get noteTooLong => menuNoteLength(note) > maxMenuNoteLength;

  /// Hay algo para guardar: cambios o, sin menú guardado, un menú que no está
  /// vacío (los platos que eligió la clienta se guardan como están).
  bool get canSave =>
      !busy &&
      !locked &&
      !noteTooLong &&
      (dirty || (version == null && content != const WeekMenuContent()));

  /// Se puede tocar «Mandar»: hay platos y nada se está guardando ni leyendo.
  /// Con cambios sin guardar, primero se guarda ([needsSaveBeforeSend]).
  bool get canSend => !busy && !locked && dishes.isNotEmpty;

  /// La clienta recibe el menú guardado: con cambios sin guardar, o un menú
  /// que todavía no se guardó (como los platos que eligió en la web), antes
  /// de mandarlo hay que guardarlo.
  bool get needsSaveBeforeSend => dirty || version == null;

  bool get canAddDish => dishes.length < maxMenuDishes;

  bool get canAddItem => items.length < maxShoppingItems;

  ShoppingListMode get listMode => listStale
      ? ShoppingListMode.stale
      : manualList
      ? ShoppingListMode.manual
      : ShoppingListMode.automatic;

  /// La pista «Son los platos que eligió la clienta…»: mientras el menú
  /// empezó con ellos, no se guardó y todos sus platos son de esos (cambiar
  /// porciones, el orden o quitar alguno no la apaga; agregar otro, sí).
  bool get showsWishesHint =>
      fromWishes &&
      !locked &&
      dishes.isNotEmpty &&
      dishes.every((dish) => wishIds.contains(dish.recipe.id));

  /// Los platos que no tienen ingredientes cargados: no suman nada a la
  /// lista.
  List<Recipe> get dishesWithoutIngredients => [
    for (final dish in dishes)
      if (dish.recipe.ingredients.isEmpty) dish.recipe,
  ];

  @override
  String toString() => 'WeekMenuEditorState($sessionId, v$version)';
}

/// Resultado de [WeekMenuEditorController.save].
enum WeekMenuSaveResult {
  saved,

  /// La nota es demasiado larga: no se mandó nada.
  invalid,

  /// El servidor no lo guardó (ver [WeekMenuEditorState.saveError]): lo
  /// escrito sigue.
  failed,

  /// Ya se estaba guardando o leyendo, no hay menú cargado o la sesión no
  /// admite cambios.
  busy,
}

/// El editor del menú de la sesión [sessionId]. Error si no se puede cargar
/// ([MenuFailure] o SessionFailure), sin reintentar solo: la pantalla ofrece
/// «Reintentar».
final weekMenuEditorProvider = AsyncNotifierProvider.autoDispose
    .family<WeekMenuEditorController, WeekMenuEditorState, String>(
      WeekMenuEditorController.new,
      retry: (_, _) => null,
    );

/// Las restricciones de la reserva de la sesión [sessionId] (null mientras
/// carga).
final weekMenuRestrictionsProvider = Provider.autoDispose
    .family<MenuRestrictions?, String>((ref, sessionId) {
      final session = ref.watch(
        sessionDetailProvider(sessionId)
            .select((detail) => detail.value?.session),
      );
      return session == null ? null : menuRestrictionsOf(session);
    });

/// Los platos del editor de [sessionId] que chocan con las restricciones de
/// la reserva, por id de receta, en el orden del menú.
final weekMenuConflictsProvider = Provider.autoDispose
    .family<Map<String, DishConflict>, String>((ref, sessionId) {
      final restrictions = ref.watch(weekMenuRestrictionsProvider(sessionId));
      final dishes = ref.watch(
        weekMenuEditorProvider(sessionId)
            .select((state) => state.value?.dishes),
      );
      if (restrictions == null || dishes == null) return const {};
      return {
        for (final dish in dishes)
          if (dishConflict(dish.recipe, restrictions) case final conflict
              when conflict.isNotEmpty)
            dish.recipe.id: conflict,
      };
    });

class WeekMenuEditorController extends AsyncNotifier<WeekMenuEditorState> {
  WeekMenuEditorController(this.sessionId);

  final String sessionId;

  /// Clave del próximo renglón.
  int _nextKey = 0;

  /// El último guardado que se quedó sin respuesta (pudo haberse aplicado);
  /// null si no hay. Se olvida con cualquier respuesta del servidor.
  WeekMenuSave? _unconfirmed;

  SessionMenusRepository get _repository =>
      ref.read(sessionMenusRepositoryProvider);

  @override
  Future<WeekMenuEditorState> build() async {
    final chefId = ref.watch(
      currentChefProvider.select((chef) => chef?.chefId),
    );
    if (chefId == null) throw const MenuFailure(MenuFailureKind.forbidden);
    // La ficha de la sesión (sus personas, su reserva y su pedido) queda
    // viva mientras el editor está abierto. Se lee una vez: si la sesión
    // cambia mientras se edita, el formulario no se rearma.
    final detail = sessionDetailProvider(sessionId);
    ref.listen(detail, (_, _) {});
    return _load(chefId, await ref.read(detail.future), generation: 0);
  }

  Future<WeekMenuEditorState> _load(
    String chefId,
    SessionDetail? detail, {
    required int generation,
  }) async {
    if (detail == null) {
      throw const MenuFailure(MenuFailureKind.sessionNotFound);
    }
    final session = detail.session;
    final saved = await _repository.fetchMenu(
      chefId: chefId,
      sessionId: sessionId,
    );
    final portions = defaultDishPortions(session);
    var dishes = saved.dishes;
    var fromWishes = false;
    final wishes = session.request?.wishes ?? const <String>[];
    if (!saved.exists &&
        saved.dishes.isEmpty &&
        saved.items.isEmpty &&
        wishes.isNotEmpty &&
        isFirstWeekOfBooking(session, detail.booking)) {
      final catalog = await ref.read(recipeCatalogProvider.future);
      dishes = dishesFromWishes(wishes, catalog, portions: portions);
      fromWishes = dishes.isNotEmpty;
    }
    final generated = buildShoppingList(dishes);
    final follows = fromWishes || _sameItems(saved.items, generated.items);
    final items = follows ? generated.items : saved.items;
    final state = WeekMenuEditorState(
      sessionId: sessionId,
      detail: detail,
      version: saved.version,
      dishes: dishes,
      items: [for (final item in items) (key: _nextKey++, item: item)],
      manualList: !follows,
      listStale: !follows,
      listTruncated: follows && generated.truncated,
      note: saved.note ?? '',
      defaultPortions: portions,
      fromWishes: fromWishes,
      wishIds: fromWishes
          ? [for (final dish in dishes) dish.recipe.id]
          : const [],
      readOnly: !isMenuEditable(session.status),
      generation: generation,
    );
    return state.copyWith(initial: state.content);
  }

  /// El estado si se puede cambiar algo (no guarda ni lee, y la sesión
  /// admite cambios); null si no.
  WeekMenuEditorState? get _editable {
    final current = state.value;
    return current == null || current.busy || current.locked ? null : current;
  }

  void _set(WeekMenuEditorState next) => state = AsyncData(next);

  /// Cambia los platos y, si la lista sigue a los platos, la rehace.
  void _setDishes(WeekMenuEditorState current, List<WeekMenuDish> dishes) {
    final next = current.copyWith(dishes: dishes);
    _set(next.manualList ? next : _withGeneratedList(next));
  }

  /// La lista sale de los platos y los sigue (también deja de decir que no
  /// coincidía al abrir).
  WeekMenuEditorState _withGeneratedList(WeekMenuEditorState current) {
    final generated = buildShoppingList(current.dishes);
    return current.copyWith(
      items: [
        for (final item in generated.items) (key: _nextKey++, item: item),
      ],
      manualList: false,
      listStale: false,
      listTruncated: generated.truncated,
      listRevision: current.listRevision + 1,
    );
  }

  /// Un cambio a mano de la lista ([items]): deja de seguir a los platos.
  WeekMenuEditorState _withManualList(
    WeekMenuEditorState current,
    List<ShoppingRow> items,
  ) => current.copyWith(
    items: items,
    manualList: true,
    listStale: false,
    listTruncated: false,
    listRevision: current.listRevision + 1,
  );

  /// Agrega al final [recipes] que todavía no están, con las porciones por
  /// defecto, hasta [maxMenuDishes]. Devuelve cuántos agregó.
  int addDishes(Iterable<Recipe> recipes) {
    final current = _editable;
    if (current == null) return 0;
    final present = {for (final dish in current.dishes) dish.recipe.id};
    final added = <WeekMenuDish>[];
    for (final recipe in recipes) {
      if (current.dishes.length + added.length >= maxMenuDishes) break;
      if (present.add(recipe.id)) {
        added.add(
          WeekMenuDish(recipe: recipe, portions: current.defaultPortions),
        );
      }
    }
    if (added.isNotEmpty) _setDishes(current, [...current.dishes, ...added]);
    return added.length;
  }

  /// Las porciones del plato [recipeId], de 1 a [maxDishPortions].
  void setPortions(String recipeId, int portions) {
    final current = _editable;
    if (current == null) return;
    final value = portions.clamp(1, maxDishPortions);
    _setDishes(current, [
      for (final dish in current.dishes)
        dish.recipe.id == recipeId ? dish.copyWith(portions: value) : dish,
    ]);
  }

  /// Mueve el plato [recipeId] [offset] lugares (-1 sube, 1 baja). En los
  /// bordes no hace nada.
  void moveDish(String recipeId, int offset) {
    final current = _editable;
    if (current == null) return;
    final dishes = [...current.dishes];
    final from = dishes.indexWhere((dish) => dish.recipe.id == recipeId);
    final to = from + offset;
    if (from < 0 || to < 0 || to >= dishes.length) return;
    dishes.insert(to, dishes.removeAt(from));
    _setDishes(current, dishes);
  }

  /// Quita el plato [recipeId]. Devuelve el plato y su lugar (para
  /// [restoreDish]), o null si no estaba.
  RemovedDish? removeDish(String recipeId) {
    final current = _editable;
    if (current == null) return null;
    final dishes = [...current.dishes];
    final index = dishes.indexWhere((dish) => dish.recipe.id == recipeId);
    if (index < 0) return null;
    final dish = dishes.removeAt(index);
    _setDishes(current, dishes);
    return (dish: dish, index: index);
  }

  /// «Deshacer» de [removeDish]: el plato vuelve a su lugar (si no se volvió a
  /// agregar y hay lugar).
  void restoreDish(RemovedDish removed) {
    final current = _editable;
    if (current == null || !current.canAddDish) return;
    final dishes = [...current.dishes];
    if (dishes.any((dish) => dish.recipe.id == removed.dish.recipe.id)) return;
    dishes.insert(removed.index.clamp(0, dishes.length), removed.dish);
    _setDishes(current, dishes);
  }

  /// Cambia el renglón [key]: la lista queda a mano.
  void updateItem(int key, ShoppingItem item) {
    final current = _editable;
    if (current == null) return;
    _set(
      _withManualList(current, [
        for (final row in current.items)
          row.key == key ? (key: key, item: item) : row,
      ]),
    );
  }

  /// Agrega un renglón (al final de su sección): la lista queda a mano.
  /// Devuelve su clave, o null si ya hay [maxShoppingItems].
  int? addItem(ShoppingItem item) {
    final current = _editable;
    if (current == null || !current.canAddItem) return null;
    final key = _nextKey++;
    _set(_withManualList(current, [...current.items, (key: key, item: item)]));
    return key;
  }

  /// Quita el renglón [key]: la lista queda a mano. Devuelve el renglón, su
  /// lugar y cómo estaba la lista (para [restoreItem]), o null si no estaba.
  RemovedShoppingRow? removeItem(int key) {
    final current = _editable;
    if (current == null) return null;
    final items = [...current.items];
    final index = items.indexWhere((row) => row.key == key);
    if (index < 0) return null;
    final row = items.removeAt(index);
    final next = _withManualList(current, items);
    _set(next);
    return (
      row: row,
      index: index,
      wasManual: current.manualList,
      wasStale: current.listStale,
      revision: next.listRevision,
    );
  }

  /// «Deshacer» de [removeItem], solo si la lista no cambió después (si se
  /// rehízo o se tocó otro renglón, no hace nada: nunca duplica). Si la lista
  /// seguía a los platos, los vuelve a seguir (con los platos de ahora); si
  /// no, el renglón vuelve a su lugar.
  void restoreItem(RemovedShoppingRow removed) {
    final current = _editable;
    if (current == null || current.listRevision != removed.revision) return;
    if (!removed.wasManual) {
      _set(_withGeneratedList(current));
      return;
    }
    if (!current.canAddItem) return;
    final items = [...current.items];
    items.insert(removed.index.clamp(0, items.length), removed.row);
    _set(
      current.copyWith(
        items: items,
        listStale: removed.wasStale,
        listRevision: current.listRevision + 1,
      ),
    );
  }

  /// «Rehacer la lista con los platos»: la lista vuelve a salir de los platos
  /// y los sigue otra vez.
  void rebuildList() {
    final current = _editable;
    if (current == null) return;
    _set(_withGeneratedList(current));
  }

  void setNote(String note) {
    final current = _editable;
    if (current == null) return;
    _set(current.copyWith(note: note));
  }

  /// Evelyn eligió descartar lo que no guardó: la pantalla ya puede salir.
  void allowLeave() {
    final current = state.value;
    if (current == null) return;
    _set(current.copyWith(leaving: true));
  }

  /// Guarda el menú entero con la versión cargada. [allergensConfirmed]:
  /// Evelyn confirmó los platos que chocan con las restricciones (false si no
  /// hay choques). Si otro teléfono lo guardó en el medio, o falla la red, lo
  /// escrito queda y [WeekMenuEditorState.saveError] dice por qué.
  Future<WeekMenuSaveResult> save({required bool allergensConfirmed}) async {
    final current = _editable;
    if (current == null) return WeekMenuSaveResult.busy;
    if (current.noteTooLong) return WeekMenuSaveResult.invalid;
    final chefId = ref.read(currentChefProvider)?.chefId;
    final repository = _repository;
    final menu = WeekMenuSave(
      sessionId: sessionId,
      version: current.version,
      note: normalizeMenuNote(current.note),
      allergensConfirmed: allergensConfirmed,
      dishes: current.dishes,
      items: [for (final row in current.orderedItems) row.item],
    );
    _set(current.copyWith(saving: true, saveError: null));
    try {
      return _saved(menu, await repository.save(menu));
    } on MenuFailure catch (failure) {
      if (failure.kind == MenuFailureKind.changed && chefId != null) {
        final recovered = await _recoverOwnSave(repository, chefId, menu);
        if (recovered != null) return recovered;
      }
      return _failed(menu, failure);
    }
  }

  /// Después de menu_changed: si lo guardado es un guardado propio, el
  /// resultado (guardado, o la falla del reenvío); null si es un conflicto
  /// de verdad o no se puede leer.
  ///
  /// - Lo guardado es [menu]: la respuesta del intento anterior se perdió (o
  ///   otro teléfono guardó lo mismo). Quedó guardado.
  /// - Lo guardado es el último guardado sin respuesta ([_unconfirmed]), con
  ///   la versión siguiente a la suya (nadie guardó en el medio), y Evelyn
  ///   siguió editando: se reenvía [menu] una vez, con esa versión.
  Future<WeekMenuSaveResult?> _recoverOwnSave(
    SessionMenusRepository repository,
    String chefId,
    WeekMenuSave menu,
  ) async {
    final SavedWeekMenu server;
    try {
      server = await repository.fetchMenu(chefId: chefId, sessionId: sessionId);
    } on MenuFailure {
      return null;
    }
    final version = server.version;
    if (version == null) return null;
    if (server.matches(menu)) return _saved(menu, version);
    final unconfirmed = _unconfirmed;
    if (unconfirmed == null ||
        !server.matches(unconfirmed) ||
        version != (unconfirmed.version ?? 0) + 1) {
      return null;
    }
    _unconfirmed = null;
    final latest = ref.mounted ? state.value : null;
    if (latest != null) {
      // Lo que se guardó sin respuesta es lo guardado; lo de después sigue
      // como cambio sin guardar si el reenvío falla.
      _set(
        latest.copyWith(
          version: version,
          fromWishes: false,
          initial: WeekMenuContent.of(unconfirmed),
        ),
      );
    }
    final retry = menu.copyWith(version: version);
    try {
      return _saved(retry, await repository.save(retry));
    } on MenuFailure catch (failure) {
      return _failed(retry, failure);
    }
  }

  /// [menu] no se guardó por [failure]: lo escrito queda. Sin respuesta, se
  /// recuerda (pudo haberse aplicado). Si la sesión ya no admite menú o ya no
  /// existe, el editor queda bloqueado y la ficha se vuelve a leer. Con
  /// cualquier respuesta del servidor que diga que el menú cambió o la
  /// sesión, la ficha y la reserva vuelven a contar el menú.
  WeekMenuSaveResult _failed(WeekMenuSave menu, MenuFailure failure) {
    _unconfirmed = failure.kind == MenuFailureKind.unavailable ? menu : null;
    if (!ref.mounted) return WeekMenuSaveResult.failed;
    final blocks =
        failure.kind == MenuFailureKind.notEditable ||
        failure.kind == MenuFailureKind.sessionNotFound;
    if (blocks || failure.kind == MenuFailureKind.changed) {
      ref
        ..invalidate(weekMenuSummaryProvider)
        ..invalidate(bookingWeekMenusProvider);
      ref.read(weekMenusRevisionProvider.notifier).bump();
    }
    if (blocks) {
      // La ficha (que el editor mantiene viva) dice ahora cómo quedó.
      unawaited(
        ref.read(sessionDetailProvider(sessionId).notifier).reloadQuietly(),
      );
    }
    final latest = state.value;
    if (latest != null) {
      _set(
        latest.copyWith(
          saving: false,
          saveError: failure,
          blockedBy: blocks ? failure.kind : latest.blockedBy,
        ),
      );
    }
    return WeekMenuSaveResult.failed;
  }

  WeekMenuSaveResult _saved(WeekMenuSave menu, int version) {
    _unconfirmed = null;
    if (!ref.mounted) return WeekMenuSaveResult.saved;
    // La ficha, la reserva y Hoy cuentan el menú nuevo.
    ref
      ..invalidate(weekMenuSummaryProvider)
      ..invalidate(bookingWeekMenusProvider);
    ref.read(weekMenusRevisionProvider.notifier).bump();
    final current = state.value;
    if (current == null) return WeekMenuSaveResult.saved;
    _set(
      current.copyWith(
        saving: false,
        saveError: null,
        version: version,
        fromWishes: false,
        initial: WeekMenuContent.of(menu),
      ),
    );
    return WeekMenuSaveResult.saved;
  }

  /// Vuelve a leer lo guardado (después de menu_changed) y descarta lo que no
  /// se guardó. Devuelve false si no se pudo leer: queda lo que había.
  Future<bool> reload() async {
    final current = _editable;
    final chefId = ref.read(currentChefProvider)?.chefId;
    if (current == null || chefId == null) return false;
    _set(current.copyWith(reloading: true));
    try {
      final detail = await ref.read(sessionDetailProvider(sessionId).future);
      final fresh = await _load(
        chefId,
        detail,
        generation: current.generation + 1,
      );
      if (!ref.mounted) return false;
      _unconfirmed = null;
      _set(fresh);
      // La ficha, la reserva y Hoy cuentan el menú que se cargó.
      ref
        ..invalidate(weekMenuSummaryProvider)
        ..invalidate(bookingWeekMenusProvider);
      ref.read(weekMenusRevisionProvider.notifier).bump();
      return true;
    } on Object {
      final latest = ref.mounted ? state.value : null;
      if (latest != null) _set(latest.copyWith(reloading: false));
      return false;
    }
  }
}

bool _sameItems(List<ShoppingItem> a, List<ShoppingItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

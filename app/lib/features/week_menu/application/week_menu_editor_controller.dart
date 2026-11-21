// Editor del menú de una semana (SPEC 5.8, paso 4): los platos con sus
// porciones, la lista de compras y la nota para la clienta, y el guardado
// entero con save_session_menu.
//
// La lista sigue sola a los platos mientras Evelyn no la toque: cada cambio de
// platos o porciones la rehace (buildShoppingList). En cuanto cambia, quita o
// agrega un renglón queda a mano, y «Rehacer la lista con los platos» la
// vuelve a armar. Al abrir un menú guardado, sigue a los platos si lo guardado
// es justo la lista que sale de esos platos; si no, está a mano. La base no
// guarda esa marca.
//
// La semana 1 sin menú guardado empieza con los platos que eligió la clienta
// en la web (requests.wishes), los que siguen en el catálogo y activos, sin
// guardar todavía.
//
// Al guardar se manda la versión cargada: si otro teléfono guardó en el medio,
// la base no escribe nada (menu_changed) y lo escrito queda en la pantalla.
// Antes de decir eso, se mira si lo guardado ya es esto (un reintento cuya
// primera respuesta se perdió): entonces quedó guardado. Si falla por la red,
// también queda lo escrito. Nada se loguea: la nota es para la clienta.
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

/// Un renglón quitado y dónde estaba, para «Deshacer».
typedef RemovedShoppingRow = ({ShoppingRow row, int index, bool wasManual});

/// Un plato del menú, para comparar: la receta y sus porciones.
typedef MenuDishRef = ({String recipeId, int portions});

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

  @override
  String toString() => 'WeekMenuContent(${dishes.length}, ${items.length})';
}

@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class WeekMenuEditorState with _$WeekMenuEditorState {
  const factory WeekMenuEditorState({
    required String sessionId,

    /// La versión guardada que se cargó (null = todavía no hay menú).
    int? version,
    @Default(<WeekMenuDish>[]) List<WeekMenuDish> dishes,
    @Default(<ShoppingRow>[]) List<ShoppingRow> items,

    /// La lista se cambió a mano: ya no sigue a los platos.
    @Default(false) bool manualList,

    /// La lista que sale de los platos tenía más de [maxShoppingItems]
    /// renglones: quedaron los primeros.
    @Default(false) bool listTruncated,

    /// Lo escrito en la nota, tal cual.
    @Default('') String note,

    /// Lo guardado (o, en una semana 1 sin menú, los platos que eligió la
    /// clienta): sin cambios, no hay nada que guardar.
    @Default(WeekMenuContent()) WeekMenuContent initial,

    /// Porciones de un plato que se agrega ([defaultDishPortions]).
    @Default(1) int defaultPortions,

    /// Los platos son los que eligió la clienta en la web y todavía no se
    /// guardaron.
    @Default(false) bool fromWishes,

    /// La sesión ya no admite cambios de menú (cancelada, cocinada o
    /// cobrada).
    @Default(false) bool readOnly,
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

  bool get noteTooLong => menuNoteLength(note) > maxMenuNoteLength;

  /// Hay algo para guardar: cambios o, sin menú guardado, un menú que no está
  /// vacío (los platos que eligió la clienta se guardan como están).
  bool get canSave =>
      !busy &&
      !readOnly &&
      !noteTooLong &&
      (dirty || (version == null && content != const WeekMenuContent()));

  bool get canAddDish => dishes.length < maxMenuDishes;

  bool get canAddItem => items.length < maxShoppingItems;

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

  /// Ya se estaba guardando o leyendo, o no hay menú cargado.
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
      version: saved.version,
      dishes: dishes,
      items: [for (final item in items) (key: _nextKey++, item: item)],
      manualList: !follows,
      listTruncated: follows && generated.truncated,
      note: saved.note ?? '',
      defaultPortions: portions,
      fromWishes: fromWishes,
      readOnly: !isMenuEditable(session.status),
      generation: generation,
    );
    return state.copyWith(initial: state.content);
  }

  WeekMenuEditorState? get _editable {
    final current = state.value;
    return current == null || current.busy ? null : current;
  }

  void _set(WeekMenuEditorState next) => state = AsyncData(next);

  /// Cambia los platos y, si la lista sigue a los platos, la rehace.
  void _setDishes(WeekMenuEditorState current, List<WeekMenuDish> dishes) {
    final next = current.copyWith(dishes: dishes);
    _set(next.manualList ? next : _withGeneratedList(next));
  }

  WeekMenuEditorState _withGeneratedList(WeekMenuEditorState current) {
    final generated = buildShoppingList(current.dishes);
    return current.copyWith(
      items: [
        for (final item in generated.items) (key: _nextKey++, item: item),
      ],
      manualList: false,
      listTruncated: generated.truncated,
    );
  }

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
      current.copyWith(
        manualList: true,
        listTruncated: false,
        items: [
          for (final row in current.items)
            row.key == key ? (key: key, item: item) : row,
        ],
      ),
    );
  }

  /// Agrega un renglón (al final de su sección): la lista queda a mano.
  /// Devuelve su clave, o null si ya hay [maxShoppingItems].
  int? addItem(ShoppingItem item) {
    final current = _editable;
    if (current == null || !current.canAddItem) return null;
    final key = _nextKey++;
    _set(
      current.copyWith(
        manualList: true,
        listTruncated: false,
        items: [...current.items, (key: key, item: item)],
      ),
    );
    return key;
  }

  /// Quita el renglón [key]: la lista queda a mano. Devuelve el renglón y su
  /// lugar (para [restoreItem]), o null si no estaba.
  RemovedShoppingRow? removeItem(int key) {
    final current = _editable;
    if (current == null) return null;
    final items = [...current.items];
    final index = items.indexWhere((row) => row.key == key);
    if (index < 0) return null;
    final row = items.removeAt(index);
    _set(
      current.copyWith(manualList: true, listTruncated: false, items: items),
    );
    return (row: row, index: index, wasManual: current.manualList);
  }

  /// «Deshacer» de [removeItem]: el renglón vuelve a su lugar, si la lista no
  /// se rehízo mientras tanto.
  void restoreItem(RemovedShoppingRow removed) {
    final current = _editable;
    if (current == null || !current.manualList || !current.canAddItem) return;
    final items = [...current.items];
    if (items.any((row) => row.key == removed.row.key)) return;
    items.insert(removed.index.clamp(0, items.length), removed.row);
    _set(current.copyWith(items: items));
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
    if (current == null || current.readOnly) return WeekMenuSaveResult.busy;
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
        final version = await _alreadySaved(repository, chefId, menu);
        if (version != null) return _saved(menu, version);
      }
      final latest = state.value;
      if (ref.mounted && latest != null) {
        _set(latest.copyWith(saving: false, saveError: failure));
      }
      return WeekMenuSaveResult.failed;
    }
  }

  /// La versión guardada si lo guardado ya es [menu] (la respuesta del primer
  /// intento se perdió, o otro teléfono guardó lo mismo); null si no, o si no
  /// se puede leer.
  Future<int?> _alreadySaved(
    SessionMenusRepository repository,
    String chefId,
    WeekMenuSave menu,
  ) async {
    try {
      final server = await repository.fetchMenu(
        chefId: chefId,
        sessionId: sessionId,
      );
      return server.matches(menu) ? server.version : null;
    } on MenuFailure {
      return null;
    }
  }

  WeekMenuSaveResult _saved(WeekMenuSave menu, int version) {
    if (!ref.mounted) return WeekMenuSaveResult.saved;
    // La ficha y la reserva cuentan el menú nuevo.
    ref
      ..invalidate(weekMenuSummaryProvider)
      ..invalidate(bookingWeekMenusProvider);
    final current = state.value;
    if (current == null) return WeekMenuSaveResult.saved;
    _set(
      current.copyWith(
        saving: false,
        saveError: null,
        version: version,
        fromWishes: false,
        initial: WeekMenuContent(
          dishes: [
            for (final dish in menu.dishes)
              (recipeId: dish.recipe.id, portions: dish.portions),
          ],
          items: menu.items,
          note: menu.note,
        ),
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
      _set(fresh);
      return true;
    } on Object {
      final latest = state.value;
      if (ref.mounted && latest != null) {
        _set(latest.copyWith(reloading: false));
      }
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

// El menú de cada semana "en el servidor", en memoria, como save_session_menu:
// guarda todo junto, con control de versión (menu_changed si la versión no
// coincide) y solo en una sesión held, confirmed o shopping_done. Cada pedido
// se aplica en cuanto llega: los `pending…` demoran solo la respuesta, como
// una red lenta (así se simula una respuesta perdida).
import 'dart:async';

import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

class FakeSessionMenusRepository implements SessionMenusRepository {
  FakeSessionMenusRepository({
    Map<String, SavedWeekMenu> menus = const {},
    Map<String, SessionStatus> statuses = const {},
  }) : menus = {...menus},
       statuses = {...statuses};

  /// Menús guardados, por sesión.
  final Map<String, SavedWeekMenu> menus;

  /// Estado de cada sesión (sin estado: confirmed). Una que no está en
  /// [missing] existe.
  final Map<String, SessionStatus> statuses;

  /// Sesiones que no existen (o son de otra cocina).
  final Set<String> missing = {};

  /// Si no son null, la operación falla con esto (save no guarda nada).
  MenuFailure? fetchFailure;
  MenuFailure? summaryFailure;
  MenuFailure? saveFailure;

  /// El guardado se aplica pero la respuesta no llega: falla con
  /// unavailable (una respuesta perdida).
  bool loseSaveResponse = false;

  Completer<void>? pendingFetch;
  Completer<void>? pendingSave;

  final List<String> fetches = [];
  final List<List<String>> summaryCalls = [];

  /// Cada guardado recibido, en orden (también los que fallaron).
  final List<WeekMenuSave> saves = [];

  @override
  Future<SavedWeekMenu> fetchMenu({
    required String chefId,
    required String sessionId,
  }) async {
    fetches.add(sessionId);
    final found = menus[sessionId] ?? const SavedWeekMenu();
    final pending = pendingFetch;
    if (pending != null) await pending.future;
    final failure = fetchFailure;
    if (failure != null) throw failure;
    if (missing.contains(sessionId)) {
      throw const MenuFailure(MenuFailureKind.sessionNotFound);
    }
    return found;
  }

  @override
  Future<Map<String, WeekMenuSummary>> fetchSummaries({
    required String chefId,
    required List<String> sessionIds,
  }) async {
    summaryCalls.add(List.of(sessionIds));
    final failure = summaryFailure;
    if (failure != null) throw failure;
    return {
      for (final id in sessionIds)
        if (!missing.contains(id))
          id: switch (menus[id]) {
            null => const WeekMenuSummary(),
            final menu => WeekMenuSummary(
              saved: menu.exists,
              dishes: menu.dishes.length,
              items: menu.items.length,
              version: menu.version,
            ),
          },
    };
  }

  @override
  Future<int> save(WeekMenuSave menu) async {
    saves.add(menu);
    MenuFailure? refused = saveFailure;
    final current = menus[menu.sessionId];
    final status = statuses[menu.sessionId] ?? SessionStatus.confirmed;
    if (refused == null && missing.contains(menu.sessionId)) {
      refused = const MenuFailure(MenuFailureKind.sessionNotFound);
    }
    if (refused == null && !isMenuEditable(status)) {
      refused = const MenuFailure(MenuFailureKind.notEditable);
    }
    if (refused == null && current?.version != menu.version) {
      refused = const MenuFailure(MenuFailureKind.changed);
    }
    var version = 0;
    if (refused == null) {
      version = (current?.version ?? 0) + 1;
      menus[menu.sessionId] = SavedWeekMenu(
        version: version,
        note: menu.note,
        allergensConfirmed: menu.allergensConfirmed,
        dishes: menu.dishes,
        items: menu.items,
      );
    }
    final pending = pendingSave;
    if (pending != null) await pending.future;
    if (refused != null) throw refused;
    if (loseSaveResponse) {
      throw const MenuFailure(MenuFailureKind.unavailable);
    }
    return version;
  }
}

// El menú de cada semana en Supabase (migración
// 20261121090000_session_menus.sql). Se lee con la RLS, que deja ver las filas
// de la cocina a la cocinera y a sus colaboradores; el filtro explícito por
// chef_id es para el índice y para que una cocinera que además fuera clienta
// con cuenta no lea como suyo el menú de otra cocina.
//
// Se escribe solo con save_session_menu (platos, lista, nota y confirmación de
// alérgenos en una transacción, con control de versión): nunca filas sueltas.
// Ningún error se loguea: puede traer la nota o la lista. Se traduce a
// [MenuFailure] (el tipo y, si lo dice la base, qué plato) y el resto se
// descarta.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class SessionMenusRepository {
  /// El menú de la sesión [sessionId] (sin menú todavía: [SavedWeekMenu] sin
  /// versión). Lanza [MenuFailure] ([MenuFailureKind.sessionNotFound] si la
  /// sesión no existe o no es de esta cocina).
  Future<SavedWeekMenu> fetchMenu({
    required String chefId,
    required String sessionId,
  });

  /// Cuántos platos y renglones tiene el menú de cada una de [sessionIds]
  /// (las que no existen no están). Lanza [MenuFailure].
  Future<Map<String, WeekMenuSummary>> fetchSummaries({
    required String chefId,
    required List<String> sessionIds,
  });

  /// Guarda el menú con save_session_menu y devuelve la versión nueva. Lanza
  /// [MenuFailure].
  Future<int> save(WeekMenuSave menu);
}

final sessionMenusRepositoryProvider = Provider<SessionMenusRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendSessionMenusRepository()
      : SupabaseSessionMenusRepository(client);
});

enum MenuFailureKind {
  /// Sin conexión, el servidor no responde o una respuesta rota. Se puede
  /// reintentar: lo escrito sigue en la pantalla.
  unavailable,

  /// 40001 menu_changed: otro teléfono guardó el menú después de que se
  /// cargó. No se guardó nada: hay que volver a cargarlo.
  changed,

  /// 55000 session_not_editable: la sesión está cancelada, cocinada o
  /// cobrada.
  notEditable,

  /// P0002 session_not_found: la sesión ya no existe (o no es de esta
  /// cocina).
  sessionNotFound,

  /// P0002 recipe_not_found: un plato ya no existe
  /// ([MenuFailure.dishIndex] dice cuál, si la base lo dijo).
  recipeNotFound,

  /// 22023 invalid_payload o un check (23514): la app valida lo mismo antes
  /// de mandar, no debería pasar.
  invalid,

  /// 42501 not_a_chef: la cuenta no es de una cocina.
  forbidden,
}

class MenuFailure implements Exception {
  const MenuFailure(this.kind, {this.dishIndex});

  final MenuFailureKind kind;

  /// En [MenuFailureKind.recipeNotFound], el lugar del plato (desde 0), si la
  /// base lo dijo ("dishes[2].recipe_id").
  final int? dishIndex;

  @override
  String toString() => 'MenuFailure(${kind.name})';
}

class SupabaseSessionMenusRepository implements SessionMenusRepository {
  SupabaseSessionMenusRepository(this._client);

  final SupabaseClient _client;

  static const String _sessions = 'sessions';
  static const String saveFunction = 'save_session_menu';

  @override
  Future<SavedWeekMenu> fetchMenu({
    required String chefId,
    required String sessionId,
  }) => _guard(() async {
    final row = await _client
        .from(_sessions)
        .select(weekMenuColumns)
        .eq('chef_id', chefId)
        .eq('id', sessionId)
        .maybeSingle();
    if (row == null) {
      throw const MenuFailure(MenuFailureKind.sessionNotFound);
    }
    return SavedWeekMenu.fromSessionRow(row);
  });

  @override
  Future<Map<String, WeekMenuSummary>> fetchSummaries({
    required String chefId,
    required List<String> sessionIds,
  }) => _guard(() async {
    if (sessionIds.isEmpty) return const {};
    final rows = await _client
        .from(_sessions)
        .select(weekMenuSummaryColumns)
        .eq('chef_id', chefId)
        .inFilter('id', sessionIds);
    return {
      for (final row in rows)
        if (row['id'] case final String id) id: weekMenuSummaryFromRow(row),
    };
  });

  @override
  Future<int> save(WeekMenuSave menu) => _guard(() async {
    final version = await _client.rpc<dynamic>(
      saveFunction,
      params: {'p': weekMenuSavePayload(menu)},
    );
    if (version is! int) throw const FormatException('Versión inválida');
    return version;
  });

  /// Traduce los errores de save_session_menu (por el código y el mensaje) y
  /// cualquier otro de red, de PostgREST o de una fila rota a [MenuFailure].
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on MenuFailure {
      rethrow;
    } on PostgrestException catch (error) {
      throw menuFailureFrom(error.code, error.message, error.details);
    } on Object {
      throw const MenuFailure(MenuFailureKind.unavailable);
    }
  }
}

final RegExp _dishDetail = RegExp(r'^dishes\[(\d+)\]');

/// El error de la base ([code], el SQLSTATE; [message], el de raise
/// exception; [details], el DETAIL) como [MenuFailure]. Del detalle solo se
/// toma el lugar del plato.
MenuFailure menuFailureFrom(String? code, String message, Object? details) {
  switch (code) {
    case '40001':
      return const MenuFailure(MenuFailureKind.changed);
    case '55000':
      return const MenuFailure(MenuFailureKind.notEditable);
    case 'P0002':
      if (message == 'recipe_not_found') {
        final match = details is String
            ? _dishDetail.firstMatch(details)
            : null;
        return MenuFailure(
          MenuFailureKind.recipeNotFound,
          dishIndex: match == null ? null : int.tryParse(match.group(1)!),
        );
      }
      return const MenuFailure(MenuFailureKind.sessionNotFound);
    case '22023' || '23514':
      return const MenuFailure(MenuFailureKind.invalid);
    case '42501':
      return const MenuFailure(MenuFailureKind.forbidden);
    default:
      return const MenuFailure(MenuFailureKind.unavailable);
  }
}

class _NoBackendSessionMenusRepository implements SessionMenusRepository {
  const _NoBackendSessionMenusRepository();

  static const _failure = MenuFailure(MenuFailureKind.unavailable);

  @override
  Future<SavedWeekMenu> fetchMenu({
    required String chefId,
    required String sessionId,
  }) => Future.error(_failure);

  @override
  Future<Map<String, WeekMenuSummary>> fetchSummaries({
    required String chefId,
    required List<String> sessionIds,
  }) => Future.error(_failure);

  @override
  Future<int> save(WeekMenuSave menu) => Future.error(_failure);
}

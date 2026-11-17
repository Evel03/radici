// Sesiones de la cocinera: se leen con la RLS («la cocinera lee las suyas»,
// rls.sql) y se mueven o cancelan con la Edge Function `chef` (contrato
// docs/contracts/chef-api.md §5 y §6). Los estados de sesión solo cambian vía
// Edge Functions (CLAUDE.md): la app nunca escribe en `sessions`. Lo único que
// escribe es la dirección de la ficha de la clienta (`clients.address`, con la
// RLS «la cocinera gestiona los suyos» y el grant por columna de rls.sql): el
// formulario web no la pide y sin ella no hay «Cómo llegar».
//
// El filtro explícito por chef_id es para el índice (sessions_chef_date_idx) y
// para cuando haya más de una cocinera; en una sesión por id, también para que
// una cocinera que además fuera clienta con cuenta no vea en su ficha una
// sesión que no es suya («el cliente lee las suyas»). La función recibe la
// sesión de quien entró, Evelyn o un colaborador suyo (`Authorization`), y la
// región va en la URL (`?forceFunctionRegion=…`): la cabecera `x-region` no,
// porque el preflight de CORS no la permite.
//
// Ningún error se loguea: puede traer la fila, con la dirección o las
// alergias. Se traduce a [SessionFailure] (el tipo, la fecha, el estado o los
// ids) y el resto se descarta.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart'
    show SupabaseBookingsRepository;
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cuántas sesiones lee la agenda como mucho: unas pocas por semana, desde el
/// mes elegido (las reservas son de 8 semanas como mucho).
const int sessionsPageSize = 1000;

abstract interface class SessionsRepository {
  /// Las sesiones de la cocinera desde [from] (incluido), de todos los
  /// estados, por fecha y llegada. Lanza [SessionFailure].
  Future<List<CookingSession>> fetchSessions({
    required String chefId,
    required CalendarDate from,
  });

  /// La sesión [id] de la cocinera [chefId], o null si no existe (o la RLS no
  /// la deja ver). Lanza [SessionFailure].
  Future<CookingSession?> fetchSession({
    required String chefId,
    required String id,
  });

  /// Todas las sesiones de la reserva [requestId] (también las canceladas),
  /// por fecha y llegada. Lanza [SessionFailure].
  Future<List<CookingSession>> fetchBookingSessions({
    required String chefId,
    required String requestId,
  });

  /// Mueve una semana (o, con `dryRun`, solo dice cómo queda esa fecha).
  /// Lanza [SessionFailure].
  Future<MoveSessionResult> moveSession(MoveSessionRequest request);

  /// Cancela semanas, todo o nada. Lanza [SessionFailure].
  Future<CancelSessionsResult> cancelSessions(CancelSessionsRequest request);

  /// Guarda [address] en la ficha [clientId] de la cocinera [chefId]. Lanza
  /// [SessionFailure] ([SessionFailureKind.notFound] si la ficha no existe o
  /// no es suya).
  Future<void> updateClientAddress({
    required String chefId,
    required String clientId,
    required String address,
  });
}

final sessionsRepositoryProvider = Provider<SessionsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendSessionsRepository()
      : SupabaseSessionsRepository(client);
});

enum SessionFailureKind {
  /// 409: esa fecha choca con otra sesión ([SessionFailure.date]). No se
  /// movió nada.
  slotTaken,

  /// 409: esa semana ya tiene otra sesión de la misma reserva
  /// ([SessionFailure.date]). No se movió nada.
  weekTaken,

  /// 409: solo se mueve una sesión held o confirmed
  /// ([SessionFailure.status] es la actual).
  notMovable,

  /// 409: al cancelar, una sesión está cocinada o cobrada
  /// ([SessionFailure.sessionIds]). No se canceló ninguna.
  invalidTransition,

  /// 409: al cancelar, esas semanas ya están cobradas
  /// ([SessionFailure.sessionIds]). No se canceló ninguna: se puede pasar la
  /// semana al final de la reserva o cancelar solo las que no están cobradas
  /// (`hasPaymentsPlan`, en domain/session_booking.dart).
  hasPayments,

  /// 404: la sesión no existe (para esta cocinera); al guardar la dirección,
  /// la ficha.
  notFound,

  /// 403: el usuario no es la cocinera ni un colaborador suyo.
  forbidden,

  /// 401: sin sesión válida (vencida o cerrada).
  unauthorized,

  /// 400: algún campo no es válido.
  invalid,

  /// Otro 409.
  conflict,

  /// Sin conexión, la función o la base no responden, o una respuesta rota.
  /// Se puede reintentar: mover a la misma fecha o cancelar otra vez no
  /// cambia nada.
  unavailable,
}

class SessionFailure implements Exception {
  const SessionFailure(
    this.kind, {
    this.date,
    this.status,
    this.sessionIds = const [],
  });

  final SessionFailureKind kind;

  /// La fecha del choque (slotTaken, weekTaken).
  final CalendarDate? date;

  /// El estado actual de la sesión en notMovable.
  final SessionStatus? status;

  /// Las sesiones de invalidTransition y hasPayments.
  final List<String> sessionIds;

  /// Solo el tipo: ni la fecha ni los ids.
  @override
  String toString() => 'SessionFailure(${kind.name})';
}

class SupabaseSessionsRepository implements SessionsRepository {
  SupabaseSessionsRepository(this._client);

  final SupabaseClient _client;

  static const String moveFunction = 'chef/sessions/move';
  static const String cancelFunction = 'chef/sessions/cancel';

  @override
  Future<List<CookingSession>> fetchSessions({
    required String chefId,
    required CalendarDate from,
  }) => _read(() async {
    final rows = await _client
        .from('sessions')
        .select(cookingSessionColumns)
        .eq('chef_id', chefId)
        .gte('date', from.toIso())
        .order('date', ascending: true)
        .order('start_time', ascending: true)
        .limit(sessionsPageSize);
    return rows.map(CookingSession.fromJson).toList();
  });

  @override
  Future<CookingSession?> fetchSession({
    required String chefId,
    required String id,
  }) => _read(() async {
    final row = await _client
        .from('sessions')
        .select(cookingSessionColumns)
        .eq('chef_id', chefId)
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : CookingSession.fromJson(row);
  });

  @override
  Future<List<CookingSession>> fetchBookingSessions({
    required String chefId,
    required String requestId,
  }) => _read(() async {
    final rows = await _client
        .from('sessions')
        .select(cookingSessionColumns)
        .eq('chef_id', chefId)
        .eq('request_id', requestId)
        .order('date', ascending: true)
        .order('start_time', ascending: true);
    return rows.map(CookingSession.fromJson).toList();
  });

  @override
  Future<MoveSessionResult> moveSession(MoveSessionRequest request) =>
      _invoke(moveFunction, request.toBody(), MoveSessionResult.fromResponse);

  @override
  Future<CancelSessionsResult> cancelSessions(CancelSessionsRequest request) =>
      _invoke(
        cancelFunction,
        request.toBody(),
        CancelSessionsResult.fromResponse,
      );

  @override
  Future<void> updateClientAddress({
    required String chefId,
    required String clientId,
    required String address,
  }) => _read(() async {
    final updated = await _client
        .from('clients')
        .update({'address': address})
        .eq('id', clientId)
        .eq('chef_id', chefId)
        .select('id');
    // Sin filas: la ficha no existe o la RLS no la deja tocar.
    if (updated.isEmpty) {
      throw const SessionFailure(SessionFailureKind.notFound);
    }
  });

  /// Llama a la función y lee su respuesta con [read].
  Future<T> _invoke<T>(
    String function,
    Map<String, Object> body,
    T Function(Object? json) read,
  ) async {
    final Object? data;
    try {
      final response = await _client.functions.invoke(
        function,
        body: body,
        // Solo el parámetro: `region:` también mandaría x-region.
        queryParameters: const {
          'forceFunctionRegion': SupabaseBookingsRepository.functionRegion,
        },
      );
      data = response.data;
    } on FunctionsHttpException catch (error) {
      throw sessionFailureFromResponse(error.status, error.details);
    } on Object {
      // Red, relay de la plataforma o el token que no se pudo renovar.
      throw const SessionFailure(SessionFailureKind.unavailable);
    }
    try {
      return read(data);
    } on Object {
      // Una respuesta con otra forma: la pantalla nunca queda esperando.
      throw const SessionFailure(SessionFailureKind.unavailable);
    }
  }

  /// Traduce cualquier error de red, de PostgREST o de una fila rota a
  /// [SessionFailure]. No se loguea el detalle: puede traer la fila.
  Future<T> _read<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on SessionFailure {
      rethrow;
    } on Object {
      throw const SessionFailure(SessionFailureKind.unavailable);
    }
  }
}

/// Traduce una respuesta de error de la función (contrato §3) a
/// [SessionFailure]. Del cuerpo solo se usan el código, la fecha (si es una
/// fecha), el estado (si es uno de `session_status`) y los ids (si son
/// textos): nada más pasa.
SessionFailure sessionFailureFromResponse(int status, Object? body) {
  final map = body is Map ? body : const <Object?, Object?>{};
  final error = map['error'];
  final date = _dateOrNull(map['date']);
  switch (status) {
    case 400:
      return const SessionFailure(SessionFailureKind.invalid);
    case 401:
      return const SessionFailure(SessionFailureKind.unauthorized);
    case 403:
      return const SessionFailure(SessionFailureKind.forbidden);
    case 404:
      // Sin ese código, el 404 es de la plataforma (la función no está
      // desplegada): se puede reintentar más tarde.
      return error == 'sessionNotFound'
          ? const SessionFailure(SessionFailureKind.notFound)
          : const SessionFailure(SessionFailureKind.unavailable);
    case 409:
      return switch (error) {
        'slotTaken' when date != null => SessionFailure(
          SessionFailureKind.slotTaken,
          date: date,
        ),
        'weekTaken' when date != null => SessionFailure(
          SessionFailureKind.weekTaken,
          date: date,
        ),
        'sessionNotMovable' => SessionFailure(
          SessionFailureKind.notMovable,
          status: SessionStatus.fromDb(map['status']),
        ),
        'invalidTransition' => SessionFailure(
          SessionFailureKind.invalidTransition,
          sessionIds: _idsOf(map['sessionId']),
        ),
        'hasPayments' => SessionFailure(
          SessionFailureKind.hasPayments,
          sessionIds: _idsOf(map['sessionIds']),
        ),
        _ => const SessionFailure(SessionFailureKind.conflict),
      };
    case >= 400 && < 500 when status != 429:
      // 405, 413, 415: un cuerpo que la app no debería mandar.
      return const SessionFailure(SessionFailureKind.invalid);
    default:
      return const SessionFailure(SessionFailureKind.unavailable);
  }
}

CalendarDate? _dateOrNull(Object? value) {
  if (value is! String) return null;
  try {
    return CalendarDate.parse(value);
  } on FormatException {
    return null;
  }
}

/// Un id o una lista de ids (solo los textos, hasta 100).
List<String> _idsOf(Object? value) => switch (value) {
  final String id => [id],
  final List<Object?> ids => ids.whereType<String>().take(100).toList(),
  _ => const [],
};

class _NoBackendSessionsRepository implements SessionsRepository {
  const _NoBackendSessionsRepository();

  static const _failure = SessionFailure(SessionFailureKind.unavailable);

  @override
  Future<List<CookingSession>> fetchSessions({
    required String chefId,
    required CalendarDate from,
  }) => Future.error(_failure);

  @override
  Future<CookingSession?> fetchSession({
    required String chefId,
    required String id,
  }) => Future.error(_failure);

  @override
  Future<List<CookingSession>> fetchBookingSessions({
    required String chefId,
    required String requestId,
  }) => Future.error(_failure);

  @override
  Future<MoveSessionResult> moveSession(MoveSessionRequest request) =>
      Future.error(_failure);

  @override
  Future<CancelSessionsResult> cancelSessions(CancelSessionsRequest request) =>
      Future.error(_failure);

  @override
  Future<void> updateClientAddress({
    required String chefId,
    required String clientId,
    required String address,
  }) => Future.error(_failure);
}

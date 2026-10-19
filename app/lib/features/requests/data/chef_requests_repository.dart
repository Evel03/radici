// Pedidos de la cocinera en Supabase: lectura, "visto", rechazo (y deshacerlo)
// y aviso en tiempo real de pedidos nuevos (contrato
// docs/contracts/public-request.md §7).
// RLS (M1) ya limita las filas a las de su chef_id; el filtro explícito por
// chef_id es para el índice y para cuando haya más de una cocinera.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cuántos pedidos se cargan (los más recientes). Sobra para la bandeja y la
/// agenda: la fecha preferida está a 14 días como mucho de la creación.
const int requestsPageSize = 500;

abstract interface class ChefRequestsRepository {
  /// Pedidos de la cocinera, del más reciente al más viejo.
  /// Lanza [RequestsFailure].
  Future<List<ChefRequest>> fetchRequests({required String chefId});

  /// Un pedido por id, o null si no existe (o RLS no lo deja ver).
  /// Lanza [RequestsFailure].
  Future<ChefRequest?> fetchRequest(String id);

  /// Marca el pedido como visto y devuelve `seen_at` guardado (si ya estaba
  /// visto, el valor anterior). Lanza [RequestsFailure].
  Future<DateTime> markSeen(String id);

  /// Pasa el pedido de `new` a `rejected`. Lanza [RequestsFailure]
  /// ([RequestsFailureKind.conflict] si ya no estaba en `new`).
  Future<void> reject(String id);

  /// Deshace el rechazo: pasa el pedido de `rejected` a `new` (la base lo
  /// permite desde la app). Lanza [RequestsFailure]
  /// ([RequestsFailureKind.conflict] si ya no estaba en `rejected`).
  Future<void> undoReject(String id);

  /// Eventos en tiempo real: pedidos insertados para [chefId] y estado de la
  /// conexión. Al cancelar la suscripción se cierra el canal.
  Stream<RequestsRealtimeEvent> watchNewRequests({required String chefId});
}

final chefRequestsRepositoryProvider = Provider<ChefRequestsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendRequestsRepository()
      : SupabaseChefRequestsRepository(client);
});

/// Eventos del canal de tiempo real.
sealed class RequestsRealtimeEvent {
  const RequestsRealtimeEvent();
}

/// Llegó un pedido nuevo (INSERT en `requests`).
final class RequestInserted extends RequestsRealtimeEvent {
  const RequestInserted(this.requestId);

  final String requestId;
}

/// El canal quedó suscripto (también después de reconectar).
final class RealtimeConnected extends RequestsRealtimeEvent {
  const RealtimeConnected();
}

/// El canal se cortó (error, tiempo agotado o cierre). El cliente de
/// Realtime reintenta solo; al volver llega [RealtimeConnected].
final class RealtimeDisconnected extends RequestsRealtimeEvent {
  const RealtimeDisconnected();
}

enum RequestsFailureKind {
  /// Sin conexión o error del servidor.
  unavailable,

  /// El pedido no existe o no se puede ver.
  notFound,

  /// El pedido cambió de estado mientras tanto (no se pudo rechazar ni
  /// deshacer el rechazo).
  conflict,
}

class RequestsFailure implements Exception {
  const RequestsFailure(this.kind);

  final RequestsFailureKind kind;

  @override
  String toString() => 'RequestsFailure(${kind.name})';
}

/// Traduce un estado del canal de Realtime a un evento.
RequestsRealtimeEvent realtimeEventOf(RealtimeSubscribeStatus status) =>
    switch (status) {
      RealtimeSubscribeStatus.subscribed => const RealtimeConnected(),
      RealtimeSubscribeStatus.channelError ||
      RealtimeSubscribeStatus.closed ||
      RealtimeSubscribeStatus.timedOut => const RealtimeDisconnected(),
    };

/// Id del pedido insertado en un payload de Realtime, o null.
String? insertedRequestIdOf(Map<String, dynamic> newRecord) {
  final id = newRecord['id'];
  return id is String && id.isNotEmpty ? id : null;
}

class SupabaseChefRequestsRepository implements ChefRequestsRepository {
  SupabaseChefRequestsRepository(this._client, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final SupabaseClient _client;
  final DateTime Function() _clock;

  /// Cada suscripción usa un canal propio (dos pantallas o un provider
  /// reconstruido no comparten el mismo tópico).
  static int _channelCounter = 0;

  @override
  Future<List<ChefRequest>> fetchRequests({required String chefId}) =>
      _guard(() async {
        final rows = await _client
            .from('requests')
            .select(chefRequestColumns)
            .eq('chef_id', chefId)
            .order('created_at', ascending: false)
            .limit(requestsPageSize);
        return rows.map(ChefRequest.fromJson).toList();
      });

  @override
  Future<ChefRequest?> fetchRequest(String id) => _guard(() async {
    final row = await _client
        .from('requests')
        .select(chefRequestColumns)
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : ChefRequest.fromJson(row);
  });

  @override
  Future<DateTime> markSeen(String id) => _guard(() async {
    final now = _clock().toUtc().toIso8601String();
    final updated = await _client
        .from('requests')
        .update({'seen_at': now})
        .eq('id', id)
        .isFilter('seen_at', null)
        .select('seen_at');
    final seenAt = updated.isEmpty ? null : updated.first['seen_at'];
    if (seenAt is String) return DateTime.parse(seenAt);

    // Ya estaba visto (por ejemplo desde otro dispositivo): vale el guardado.
    final current = await _client
        .from('requests')
        .select('seen_at')
        .eq('id', id)
        .maybeSingle();
    final previous = current?['seen_at'];
    if (previous is String) return DateTime.parse(previous);
    throw const RequestsFailure(RequestsFailureKind.notFound);
  });

  @override
  Future<void> reject(String id) =>
      _changeStatus(id, from: 'new', to: 'rejected');

  @override
  Future<void> undoReject(String id) =>
      _changeStatus(id, from: 'rejected', to: 'new');

  /// Cambia el estado solo si todavía es [from]; si no, conflicto.
  Future<void> _changeStatus(
    String id, {
    required String from,
    required String to,
  }) => _guard(() async {
    final updated = await _client
        .from('requests')
        .update({'status': to})
        .eq('id', id)
        .eq('status', from)
        .select('id');
    if (updated.isEmpty) {
      throw const RequestsFailure(RequestsFailureKind.conflict);
    }
  });

  @override
  Stream<RequestsRealtimeEvent> watchNewRequests({required String chefId}) {
    RealtimeChannel? channel;
    late final StreamController<RequestsRealtimeEvent> controller;

    void emit(RequestsRealtimeEvent event) {
      if (!controller.isClosed) controller.add(event);
    }

    controller = StreamController<RequestsRealtimeEvent>(
      onListen: () {
        channel = _client
            .channel('chef-requests-$chefId-${_channelCounter++}')
            .onPostgresChanges(
              event: PostgresChangeEvent.insert,
              schema: 'public',
              table: 'requests',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'chef_id',
                value: chefId,
              ),
              callback: (payload) {
                final id = insertedRequestIdOf(payload.newRecord);
                if (id != null) emit(RequestInserted(id));
              },
            )
            .subscribe((status, _) => emit(realtimeEventOf(status)));
      },
      onCancel: () async {
        final open = channel;
        channel = null;
        if (open != null) await _client.removeChannel(open);
        await controller.close();
      },
    );
    return controller.stream;
  }

  /// Traduce cualquier error de red o de PostgREST a [RequestsFailure].
  /// No se loguea el detalle: puede traer datos del pedido.
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on RequestsFailure {
      rethrow;
    } on Object {
      throw const RequestsFailure(RequestsFailureKind.unavailable);
    }
  }
}

class _NoBackendRequestsRepository implements ChefRequestsRepository {
  const _NoBackendRequestsRepository();

  static const _failure = RequestsFailure(RequestsFailureKind.unavailable);

  @override
  Future<List<ChefRequest>> fetchRequests({required String chefId}) =>
      Future.error(_failure);

  @override
  Future<ChefRequest?> fetchRequest(String id) => Future.error(_failure);

  @override
  Future<DateTime> markSeen(String id) => Future.error(_failure);

  @override
  Future<void> reject(String id) => Future.error(_failure);

  @override
  Future<void> undoReject(String id) => Future.error(_failure);

  @override
  Stream<RequestsRealtimeEvent> watchNewRequests({required String chefId}) =>
      const Stream.empty();
}

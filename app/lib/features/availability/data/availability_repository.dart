// Disponibilidad de la cocinera en Supabase: horario semanal
// (`availability_rules`) y días bloqueados (`availability_exceptions`).
// La RLS ya limita las filas a las de su chef_id ("la cocinera gestiona las
// suyas", rls.sql); el filtro explícito por chef_id es para el índice y para
// cuando haya más de una cocinera. No hace falta ninguna migración: la tabla,
// la política y los grants existen desde M1.
//
// Las notas de los bloqueos son privadas: nada de esto se loguea.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Un día para bloquear, con su nota (null = sin nota).
typedef DayToBlock = ({CalendarDate date, String? note});

abstract interface class AvailabilityRepository {
  /// Horario semanal y días bloqueados desde [from] (incluido).
  /// Lanza [AvailabilityFailure].
  Future<AvailabilitySnapshot> fetch({
    required String chefId,
    required CalendarDate from,
  });

  /// Bloquea [days]. Un día que ya estaba bloqueado no se toca (ni su nota):
  /// devuelve solo los bloqueos creados, así «Deshacer» nunca borra uno que
  /// ya existía. Lanza [AvailabilityFailure].
  Future<List<BlockedDay>> block({
    required String chefId,
    required List<DayToBlock> days,
  });

  /// Quita los bloqueos [ids]. Lanza [AvailabilityFailure].
  Future<void> unblock({required String chefId, required List<String> ids});

  /// Cambia la nota del bloqueo [id] (null la borra). Lanza
  /// [AvailabilityFailure] ([AvailabilityFailureKind.notFound] si el bloqueo
  /// ya no existe).
  Future<void> updateNote({
    required String chefId,
    required String id,
    String? note,
  });
}

final availabilityRepositoryProvider = Provider<AvailabilityRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendAvailabilityRepository()
      : SupabaseAvailabilityRepository(client);
});

enum AvailabilityFailureKind {
  /// Sin conexión o error del servidor.
  unavailable,

  /// El bloqueo ya no existe (por ejemplo, se quitó desde otro dispositivo).
  notFound,
}

class AvailabilityFailure implements Exception {
  const AvailabilityFailure(this.kind);

  final AvailabilityFailureKind kind;

  @override
  String toString() => 'AvailabilityFailure(${kind.name})';
}

class SupabaseAvailabilityRepository implements AvailabilityRepository {
  SupabaseAvailabilityRepository(this._client);

  final SupabaseClient _client;

  static const String _rules = 'availability_rules';
  static const String _exceptions = 'availability_exceptions';

  /// `exception_kind`: hoy solo existe 'blocked'.
  static const String _blocked = 'blocked';

  @override
  Future<AvailabilitySnapshot> fetch({
    required String chefId,
    required CalendarDate from,
  }) => _guard(() async {
    final (rules, blocked) = await (
      _client
          .from(_rules)
          .select(availabilityRuleColumns)
          .eq('chef_id', chefId)
          .order('dow', ascending: true)
          .order('start_time', ascending: true),
      _client
          .from(_exceptions)
          .select(blockedDayColumns)
          .eq('chef_id', chefId)
          .eq('kind', _blocked)
          .gte('date', from.toIso())
          .order('date', ascending: true),
    ).wait;
    final days = blocked.map(BlockedDay.fromJson);
    return AvailabilitySnapshot(
      rules: rules.map(AvailabilityRule.fromJson).toList(),
      blocked: {for (final day in days) day.date: day},
    );
  });

  @override
  Future<List<BlockedDay>> block({
    required String chefId,
    required List<DayToBlock> days,
  }) async {
    if (days.isEmpty) return const [];
    return _guard(() async {
      // on conflict do nothing: devuelve solo las filas creadas.
      final rows = await _client
          .from(_exceptions)
          .upsert(
            [
              for (final day in days)
                {
                  'chef_id': chefId,
                  'date': day.date.toIso(),
                  'kind': _blocked,
                  'note': day.note,
                },
            ],
            onConflict: 'chef_id,date,kind',
            ignoreDuplicates: true,
          )
          .select(blockedDayColumns);
      return rows.map(BlockedDay.fromJson).toList();
    });
  }

  @override
  Future<void> unblock({
    required String chefId,
    required List<String> ids,
  }) async {
    if (ids.isEmpty) return;
    await _guard(
      () => _client
          .from(_exceptions)
          .delete()
          .eq('chef_id', chefId)
          .inFilter('id', ids),
    );
  }

  @override
  Future<void> updateNote({
    required String chefId,
    required String id,
    String? note,
  }) => _guard(() async {
    final updated = await _client
        .from(_exceptions)
        .update({'note': note})
        .eq('chef_id', chefId)
        .eq('id', id)
        .select('id');
    if (updated.isEmpty) {
      throw const AvailabilityFailure(AvailabilityFailureKind.notFound);
    }
  });

  /// Traduce cualquier error de red, de PostgREST o de una fila rota a
  /// [AvailabilityFailure]. No se loguea el detalle: puede traer notas.
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on AvailabilityFailure {
      rethrow;
    } on Object {
      throw const AvailabilityFailure(AvailabilityFailureKind.unavailable);
    }
  }
}

class _NoBackendAvailabilityRepository implements AvailabilityRepository {
  const _NoBackendAvailabilityRepository();

  static const _failure = AvailabilityFailure(
    AvailabilityFailureKind.unavailable,
  );

  @override
  Future<AvailabilitySnapshot> fetch({
    required String chefId,
    required CalendarDate from,
  }) => Future.error(_failure);

  @override
  Future<List<BlockedDay>> block({
    required String chefId,
    required List<DayToBlock> days,
  }) => Future.error(_failure);

  @override
  Future<void> unblock({required String chefId, required List<String> ids}) =>
      Future.error(_failure);

  @override
  Future<void> updateNote({
    required String chefId,
    required String id,
    String? note,
  }) => Future.error(_failure);
}

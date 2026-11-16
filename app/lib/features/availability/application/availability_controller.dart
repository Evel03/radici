// Disponibilidad de la cocinera para la agenda: su horario y los días que
// bloqueó. Bloquear y desbloquear se ven enseguida y vuelven atrás si el
// servidor falla; cada acción devuelve lo que cambió, para «Deshacer».
// Entre dos dispositivos alcanza con deslizar para actualizar (sin Realtime).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';

final availabilityControllerProvider =
    AsyncNotifierProvider<AvailabilityController, AvailabilitySnapshot>(
      AvailabilityController.new,
    );

/// Días que se están guardando: sus botones van deshabilitados.
final availabilitySavingProvider =
    NotifierProvider<AvailabilitySaving, Set<CalendarDate>>(
      AvailabilitySaving.new,
    );

class AvailabilitySaving extends Notifier<Set<CalendarDate>> {
  @override
  Set<CalendarDate> build() => const {};

  void _add(Iterable<CalendarDate> days) => state = {...state, ...days};

  void _remove(Iterable<CalendarDate> days) =>
      state = state.difference(days.toSet());
}

/// La disponibilidad está cargada y vale: no se está volviendo a leer porque
/// cambió la cocinera o el mes (deslizar para actualizar no la invalida).
final availabilityReadyProvider = Provider<bool>((ref) {
  final availability = ref.watch(availabilityControllerProvider);
  return availability.hasValue && !availability.isReloading;
});

/// Lo que la agenda muestra de [day]; null mientras se carga la
/// disponibilidad (o si no se pudo cargar).
final agendaDayAvailabilityProvider = Provider.autoDispose
    .family<AgendaDayAvailability?, CalendarDate>((ref, day) {
      if (!ref.watch(availabilityReadyProvider)) return null;
      final snapshot = ref.watch(availabilityControllerProvider).value;
      if (snapshot == null) return null;
      final requestCount = ref.watch(
        agendaByDateProvider.select((byDate) => byDate[day]?.length ?? 0),
      );
      return agendaDayAvailability(
        day: day,
        today: ref.watch(romeTodayProvider),
        snapshot: snapshot,
        requestsThatDay: requestCount,
      );
    });

class AvailabilityController extends AsyncNotifier<AvailabilitySnapshot> {
  AvailabilityRepository get _repository =>
      ref.read(availabilityRepositoryProvider);

  AvailabilitySaving get _saving =>
      ref.read(availabilitySavingProvider.notifier);

  String? get _chefId => ref.read(currentChefProvider)?.chefId;

  @override
  Future<AvailabilitySnapshot> build() async {
    final chefId = ref.watch(
      currentChefProvider.select((chef) => chef?.chefId),
    );
    if (chefId == null) return AvailabilitySnapshot.empty;
    // Se vuelve a leer cuando cambia el mes (no cada medianoche).
    final from = ref.watch(romeTodayProvider.select(blockedDaysFrom));
    return ref
        .watch(availabilityRepositoryProvider)
        .fetch(chefId: chefId, from: from);
  }

  /// Bloquea [dates], todos con [note]. Se ven bloqueados enseguida. Los que
  /// ya estaban bloqueados no se tocan. Devuelve los bloqueos creados (para
  /// [undoBlock]). Si falla, todo vuelve a como estaba y se relanza
  /// [AvailabilityFailure].
  Future<List<BlockedDay>> block(
    Iterable<CalendarDate> dates, {
    String? note,
  }) {
    final clean = normalizeNote(note);
    return _block([for (final date in dates) (date: date, note: clean)]);
  }

  /// Deshace un [unblock]: vuelve a bloquear esos días, cada uno con su nota.
  /// Errores como en [block].
  Future<List<BlockedDay>> undoUnblock(List<BlockedDay> removed) =>
      _block([for (final day in removed) (date: day.date, note: day.note)]);

  Future<List<BlockedDay>> _block(List<DayToBlock> days) async {
    final chefId = _chefId;
    final current = state.value;
    if (chefId == null || current == null) return const [];
    final toSave = <CalendarDate, DayToBlock>{
      for (final day in days)
        if (!current.blocked.containsKey(day.date)) day.date: day,
    };
    if (toSave.isEmpty) return const [];

    _update(
      add: [
        for (final day in toSave.values)
          BlockedDay(date: day.date, note: day.note),
      ],
    );
    _saving._add(toSave.keys);
    try {
      final created = await _repository.block(
        chefId: chefId,
        days: toSave.values.toList(),
      );
      if (ref.mounted) {
        _update(add: created);
        // Los que no volvieron ya los había bloqueado otro dispositivo: siguen
        // bloqueados y se leen sus filas (id y nota).
        if (created.length < toSave.length) unawaited(_reloadQuietly());
      }
      return created;
    } on Object {
      if (ref.mounted) _update(removeUnsaved: toSave.keys);
      rethrow;
    } finally {
      if (ref.mounted) _saving._remove(toSave.keys);
    }
  }

  /// Desbloquea [dates]. Se ve enseguida. Devuelve los bloqueos quitados, con
  /// su nota (para [undoUnblock]). Si falla, vuelven y se relanza
  /// [AvailabilityFailure].
  Future<List<BlockedDay>> unblock(Iterable<CalendarDate> dates) async {
    final chefId = _chefId;
    if (chefId == null || state.value == null) return const [];
    final wanted = dates.toSet();
    var targets = _blockedOn(wanted);
    if (targets.any((day) => day.id == null)) {
      // Un bloqueo de otro dispositivo que todavía no se leyó: primero se lee.
      await refresh();
      targets = _blockedOn(wanted);
    }
    targets = [
      for (final day in targets)
        if (day.id != null) day,
    ];
    if (targets.isEmpty) return const [];

    final days = [for (final day in targets) day.date];
    _update(remove: days);
    _saving._add(days);
    try {
      await _repository.unblock(
        chefId: chefId,
        ids: [for (final day in targets) day.id!],
      );
      return targets;
    } on Object {
      if (ref.mounted) _update(add: targets);
      rethrow;
    } finally {
      if (ref.mounted) _saving._remove(days);
    }
  }

  /// Deshace un [block]: quita solo los bloqueos que creó, nunca uno que ya
  /// existía. Errores como en [unblock].
  Future<void> undoBlock(List<BlockedDay> created) async {
    final ids = {
      for (final day in created)
        if (day.id != null) day.id,
    };
    final blocked = state.value?.blocked.values ?? const <BlockedDay>[];
    await unblock([
      for (final day in blocked)
        if (ids.contains(day.id)) day.date,
    ]);
  }

  /// Cambia la nota del día bloqueado [date] (vacía = sin nota). Se ve
  /// enseguida; si falla, vuelve la anterior y se relanza
  /// [AvailabilityFailure]. Si el bloqueo ya no existía, además se vuelve a
  /// leer todo.
  Future<void> setNote(CalendarDate date, String? note) async {
    final chefId = _chefId;
    if (chefId == null) return;
    var day = state.value?.blocked[date];
    if (day != null && day.id == null) {
      await refresh();
      day = state.value?.blocked[date];
    }
    final id = day?.id;
    if (day == null || id == null) return;
    final clean = normalizeNote(note);
    if (clean == day.note) return;

    final previous = day;
    _update(add: [previous.copyWith(note: clean)]);
    _saving._add([date]);
    try {
      await _repository.updateNote(chefId: chefId, id: id, note: clean);
    } on Object catch (error) {
      if (ref.mounted) {
        _update(add: [previous]);
        if (error is AvailabilityFailure &&
            error.kind == AvailabilityFailureKind.notFound) {
          unawaited(_reloadQuietly());
        }
      }
      rethrow;
    } finally {
      if (ref.mounted) _saving._remove([date]);
    }
  }

  /// Vuelve a leer todo (deslizar para actualizar). Si falla, queda lo que
  /// había y se relanza [AvailabilityFailure].
  Future<void> refresh() async {
    final chefId = _chefId;
    if (chefId == null) return;
    final from = blockedDaysFrom(ref.read(romeTodayProvider));
    final fresh = await _repository.fetch(chefId: chefId, from: from);
    if (ref.mounted) state = AsyncData(fresh);
  }

  Future<void> _reloadQuietly() async {
    try {
      await refresh();
    } on AvailabilityFailure {
      // Queda lo local; deslizar para actualizar lo corrige.
    }
  }

  /// Los bloqueos de [dates], por fecha.
  List<BlockedDay> _blockedOn(Set<CalendarDate> dates) {
    final blocked = state.value?.blocked ?? const <CalendarDate, BlockedDay>{};
    return [for (final date in dates.toList()..sort()) ?blocked[date]];
  }

  /// Cambia los bloqueos de la foto: saca [remove], saca los de
  /// [removeUnsaved] que todavía no tienen id, y pone [add].
  void _update({
    Iterable<BlockedDay> add = const [],
    Iterable<CalendarDate> remove = const [],
    Iterable<CalendarDate> removeUnsaved = const [],
  }) {
    final current = state.value;
    if (current == null) return;
    final blocked = {...current.blocked};
    for (final date in remove) {
      blocked.remove(date);
    }
    for (final date in removeUnsaved) {
      if (blocked[date]?.id == null) blocked.remove(date);
    }
    for (final day in add) {
      blocked[day.date] = day;
    }
    state = AsyncData(current.copyWith(blocked: blocked));
  }
}

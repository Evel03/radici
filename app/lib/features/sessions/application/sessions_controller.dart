// Sesiones para la agenda y para la ficha de cada sesión.
//
// - La agenda lee las de la cocinera desde el mes de hoy (o desde el mes
//   elegido, si es anterior), con la RLS.
// - La ficha lee la sesión y todas las semanas de su reserva.
// - Mover y cancelar pasan por la Edge Function chef (SessionCommands): lo que
//   devuelve se avisa como un cambio (sessionChangesProvider) y la agenda y
//   las fichas abiertas lo aplican sin volver a leer. La dirección de la
//   ficha de la clienta se guarda con la RLS y se avisa igual.
//
// Entre dos dispositivos alcanza con deslizar para actualizar: sin Realtime de
// sesiones (plan del área de Evelyn, «Afuera a propósito»). Nada se loguea.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

part 'sessions_controller.freezed.dart';

/// Un cambio que hizo la Edge Function (no hace falta volver a leer).
sealed class SessionChange {}

/// Se movió una semana: [session] ya con su fecha, hora y minutos nuevos.
final class SessionMoved implements SessionChange {
  SessionMoved(this.session);

  final CookingSession session;
}

/// Se cancelaron semanas: [cancelled], ahora (con [reason] y [at]);
/// [alreadyCancelled], antes.
final class SessionsCancelled implements SessionChange {
  SessionsCancelled({
    required this.cancelled,
    required this.alreadyCancelled,
    required this.reason,
    required this.at,
  });

  final Set<String> cancelled;
  final Set<String> alreadyCancelled;
  final CancelReason reason;
  final DateTime at;

  /// Aplica el cambio a [session] (si es una de las canceladas).
  CookingSession applyTo(CookingSession session) {
    if (cancelled.contains(session.id)) {
      return session.copyWith(
        status: SessionStatus.cancelled,
        cancelledAt: at,
        cancelReason: reason.code,
      );
    }
    if (alreadyCancelled.contains(session.id) && session.isLive) {
      return session.copyWith(status: SessionStatus.cancelled);
    }
    return session;
  }
}

/// Se guardó la dirección de la ficha [clientId]: vale para todas sus
/// sesiones. No se imprime.
final class ClientAddressChanged implements SessionChange {
  ClientAddressChanged({required this.clientId, required this.address});

  final String clientId;
  final String address;

  /// Aplica el cambio a [session] (si es de esa ficha).
  CookingSession applyTo(CookingSession session) => session.clientId == clientId
      ? session.copyWith(client: session.client.copyWith(address: address))
      : session;

  @override
  String toString() => 'ClientAddressChanged($clientId)';
}

/// El último cambio. Cada uno es un objeto nuevo: todos avisan, también dos
/// iguales seguidos.
final sessionChangesProvider = NotifierProvider<SessionChanges, SessionChange?>(
  SessionChanges.new,
);

class SessionChanges extends Notifier<SessionChange?> {
  @override
  SessionChange? build() => null;

  void emit(SessionChange change) => state = change;
}

/// Desde qué día lee la agenda las sesiones ([sessionsWindowFrom]). Cambia
/// solo si se elige un mes anterior al de hoy (o cambia el mes de hoy).
final sessionsFromProvider = Provider<CalendarDate>(
  (ref) => sessionsWindowFrom(
    today: ref.watch(romeTodayProvider),
    selected: ref.watch(agendaControllerProvider.select((s) => s.selectedDay)),
  ),
);

/// Las sesiones de la agenda: las de la cocinera desde [sessionsFromProvider],
/// de todos los estados.
final sessionsControllerProvider =
    AsyncNotifierProvider<SessionsController, List<CookingSession>>(
      SessionsController.new,
    );

/// Las sesiones vivas de la agenda por día, por llegada. Vacío mientras
/// cargan (o si no se pudieron leer).
final agendaSessionsByDateProvider =
    Provider<Map<CalendarDate, List<CookingSession>>>(
      (ref) => sessionsByDate(
        ref.watch(sessionsControllerProvider).value ?? const [],
      ),
    );

class SessionsController extends AsyncNotifier<List<CookingSession>> {
  SessionsRepository get _repository => ref.read(sessionsRepositoryProvider);

  /// Suma uno con cada cambio aplicado: una lectura que se cruzó con uno
  /// puede ser de antes.
  int _changes = 0;

  @override
  Future<List<CookingSession>> build() async {
    final chefId = ref.watch(
      currentChefProvider.select((chef) => chef?.chefId),
    );
    if (chefId == null) return const [];
    ref.listen(sessionChangesProvider, (_, change) {
      if (change != null) _apply(change);
    });
    final from = ref.watch(sessionsFromProvider);
    return ref
        .watch(sessionsRepositoryProvider)
        .fetchSessions(chefId: chefId, from: from);
  }

  /// Vuelve a leer (deslizar para actualizar). Si la lectura se cruzó con un
  /// cambio, se lee una vez más; si esa también, queda lo local. Si falla,
  /// queda lo que había y se relanza [SessionFailure].
  Future<void> refresh() async {
    final chefId = ref.read(currentChefProvider)?.chefId;
    if (chefId == null) return;
    for (var attempt = 0; attempt < 2; attempt++) {
      final changes = _changes;
      final fresh = await _repository.fetchSessions(
        chefId: chefId,
        from: ref.read(sessionsFromProvider),
      );
      if (!ref.mounted) return;
      if (changes == _changes) {
        state = AsyncData(fresh);
        return;
      }
    }
  }

  /// Como [refresh], sin avisar si falla (queda lo que había).
  Future<void> refreshQuietly() async {
    try {
      await refresh();
    } on SessionFailure {
      // Deslizar para actualizar lo corrige.
    }
  }

  void _apply(SessionChange change) {
    final current = state.value;
    if (current == null) return;
    _changes++;
    switch (change) {
      case SessionMoved(:final session):
        final from = ref.read(sessionsFromProvider);
        state = AsyncData(
          [
            for (final other in current)
              if (other.id != session.id) other,
            if (!session.date.isBefore(from)) session,
          ]..sort(compareSessions),
        );
      case final SessionsCancelled cancelled:
        state = AsyncData([
          for (final session in current) cancelled.applyTo(session),
        ]);
      case final ClientAddressChanged changed:
        state = AsyncData([
          for (final session in current) changed.applyTo(session),
        ]);
    }
  }
}

/// Una sesión con todas las semanas de su reserva (también las canceladas):
/// con ellas salen «Semana k de N», las siguientes y el final de la reserva.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class SessionDetail with _$SessionDetail {
  const factory SessionDetail({
    required CookingSession session,

    /// Las sesiones de su reserva; solo ella si no tiene pedido.
    required List<CookingSession> booking,
  }) = _SessionDetail;

  const SessionDetail._();

  BookingWeekPosition? get position => bookingPosition(session, booking);

  /// Las semanas siguientes que todavía se pueden cancelar.
  List<CookingSession> get following => followingSessions(session, booking);

  /// «Pasar al final de la reserva»; null si ya es la última.
  CalendarDate? get endOfBooking => endOfBookingDate(session, booking);

  /// Todas las semanas de la reserva (también las canceladas), por fecha.
  List<CookingSession> get weeks => [
    for (final other in booking)
      if (other.id != session.id) other,
    session,
  ]..sort(compareSessions);

  @override
  String toString() => 'SessionDetail(${session.id})';
}

/// La ficha de la sesión [id]: null si no existe (o la RLS no la deja ver).
final sessionDetailProvider = AsyncNotifierProvider.autoDispose
    .family<SessionDetailController, SessionDetail?, String>(
      SessionDetailController.new,
    );

class SessionDetailController extends AsyncNotifier<SessionDetail?> {
  SessionDetailController(this.sessionId);

  final String sessionId;

  @override
  Future<SessionDetail?> build() async {
    final chefId = ref.watch(
      currentChefProvider.select((chef) => chef?.chefId),
    );
    if (chefId == null) return null;
    ref.listen(sessionChangesProvider, (_, change) {
      if (change != null) _apply(change);
    });
    final repository = ref.watch(sessionsRepositoryProvider);
    // Desde la agenda ya se sabe de qué reserva es: una sola lectura.
    final known = ref.exists(sessionsControllerProvider)
        ? ref
              .read(sessionsControllerProvider)
              .value
              ?.where((s) => s.id == sessionId)
              .firstOrNull
        : null;
    return _load(repository, chefId, requestId: known?.requestId);
  }

  /// Vuelve a leer la sesión y su reserva (deslizar para actualizar, o
  /// después de un error que dice que cambió). Si falla, queda lo que había y
  /// se relanza [SessionFailure].
  Future<void> reload() async {
    final chefId = ref.read(currentChefProvider)?.chefId;
    if (chefId == null) return;
    final fresh = await _load(
      ref.read(sessionsRepositoryProvider),
      chefId,
      requestId: state.value?.session.requestId,
    );
    if (!ref.mounted) return;
    state = AsyncData(fresh);
  }

  /// Como [reload], sin avisar si falla.
  Future<void> reloadQuietly() async {
    try {
      await reload();
    } on SessionFailure {
      // Queda lo que había; deslizar para actualizar lo corrige.
    }
  }

  Future<SessionDetail?> _load(
    SessionsRepository repository,
    String chefId, {
    String? requestId,
  }) async {
    if (requestId != null) {
      final booking = await repository.fetchBookingSessions(
        chefId: chefId,
        requestId: requestId,
      );
      final session = booking.where((s) => s.id == sessionId).firstOrNull;
      if (session != null) {
        return SessionDetail(session: session, booking: booking);
      }
      // Ya no es de esa reserva (o no existe): se lee sola.
    }
    final session = await repository.fetchSession(
      chefId: chefId,
      id: sessionId,
    );
    if (session == null) return null;
    final ownRequest = session.requestId;
    if (ownRequest == null) {
      return SessionDetail(session: session, booking: [session]);
    }
    final booking = await repository.fetchBookingSessions(
      chefId: chefId,
      requestId: ownRequest,
    );
    return SessionDetail(session: session, booking: booking);
  }

  void _apply(SessionChange change) {
    final current = state.value;
    if (current == null) return;
    CookingSession patch(CookingSession session) => switch (change) {
      SessionMoved(session: final moved) when moved.id == session.id => moved,
      SessionMoved() => session,
      final SessionsCancelled cancelled => cancelled.applyTo(session),
      final ClientAddressChanged changed => changed.applyTo(session),
    };
    state = AsyncData(
      current.copyWith(
        session: patch(current.session),
        booking: [for (final session in current.booking) patch(session)],
      ),
    );
  }
}

/// Sesiones con un cambio esperando al servidor (mover, deshacer o cancelar):
/// sus botones van deshabilitados (un segundo toque cruzaría los pedidos).
final sessionsBusyProvider = NotifierProvider<SessionsBusy, Set<String>>(
  SessionsBusy.new,
);

class SessionsBusy extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void _add(Iterable<String> ids) => state = {...state, ...ids};

  void _remove(Iterable<String> ids) => state = state.difference(ids.toSet());
}

/// Mover y cancelar con la Edge Function chef, y guardar la dirección de la
/// ficha. Si sale bien, avisa el cambio (la agenda y las fichas abiertas lo
/// aplican). Lanza [SessionFailure].
final sessionCommandsProvider = Provider<SessionCommands>(SessionCommands.new);

class SessionCommands {
  SessionCommands(this._ref);

  final Ref _ref;

  SessionsRepository get _repository => _ref.read(sessionsRepositoryProvider);

  /// Mueve [session] a [date] con llegada [start] (los minutos de cocina, la
  /// compra y el margen quedan los guardados). Devuelve la sesión movida.
  Future<CookingSession> move(
    CookingSession session, {
    required CalendarDate date,
    required ClockTime start,
  }) async {
    final result = await _busy(
      [session.id],
      () => _repository.moveSession(
        MoveSessionRequest(sessionId: session.id, date: date, start: start),
      ),
    );
    final moved = session.copyWith(
      date: result.date,
      start: result.start,
      cookMinutes: result.cookMinutes,
    );
    _ref.read(sessionChangesProvider.notifier).emit(SessionMoved(moved));
    return moved;
  }

  /// Cancela [sessions] con [reason], todo o nada.
  Future<CancelSessionsResult> cancel(
    List<CookingSession> sessions, {
    CancelReason reason = CancelReason.chefCancelled,
  }) async {
    final ids = [for (final session in sessions) session.id];
    final result = await _busy(
      ids,
      () => _repository.cancelSessions(
        CancelSessionsRequest(sessionIds: ids, reason: reason),
      ),
    );
    _ref
        .read(sessionChangesProvider.notifier)
        .emit(
          SessionsCancelled(
            cancelled: result.cancelled.toSet(),
            alreadyCancelled: result.alreadyCancelled.toSet(),
            reason: reason,
            at: _ref.read(clockProvider)().toUtc(),
          ),
        );
    return result;
  }

  /// Guarda [address] (ya normalizada, ver normalizeClientAddress) en la
  /// ficha de la clienta de [session]: vale para todas sus sesiones.
  Future<void> updateAddress(CookingSession session, String address) async {
    final chefId = _ref.read(currentChefProvider)?.chefId;
    if (chefId == null) {
      throw const SessionFailure(SessionFailureKind.unauthorized);
    }
    await _repository.updateClientAddress(
      chefId: chefId,
      clientId: session.clientId,
      address: address,
    );
    _ref
        .read(sessionChangesProvider.notifier)
        .emit(
          ClientAddressChanged(clientId: session.clientId, address: address),
        );
  }

  Future<T> _busy<T>(List<String> ids, Future<T> Function() body) async {
    final busy = _ref.read(sessionsBusyProvider.notifier);
    busy._add(ids);
    try {
      return await body();
    } finally {
      busy._remove(ids);
    }
  }
}

/// Para que la agenda vuelva a leer sus sesiones sin avisar después de crear
/// una reserva: la función, si la agenda ya estaba cargada (si no, las lee al
/// abrirse); null si no. Se toma antes de esperar al servidor: quien la pide
/// puede cerrarse mientras tanto.
Future<void> Function()? agendaSessionsRefresher(Ref ref) =>
    ref.exists(sessionsControllerProvider)
    ? ref.read(sessionsControllerProvider.notifier).refreshQuietly
    : null;

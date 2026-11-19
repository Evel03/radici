// Hoja «Mover la sesión»: la fecha nueva y la hora de llegada, con lo que
// dice el servidor de esa fecha antes de confirmar (el dryRun de
// POST chef/sessions/move): libre, un aviso (bloqueado, sin horario, fuera de
// horario, pasada), si choca con otra sesión o si esa semana ya tiene otra de
// la misma reserva (una por semana: se ofrece pasarla al final de la reserva).
// Con un choque no deja moverla. La compra, el margen y los minutos de cocina
// quedan los guardados.
//
// Cada cambio vuelve a pedir el dryRun y solo vale la respuesta del último.
// Mover es reversible: la ficha ofrece «Deshacer» con la fecha y la hora de
// antes. Nada de esto se loguea.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart'
    show defaultBookingArrival;
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

part 'move_session_controller.freezed.dart';

/// Una hoja por sesión; se descarta al cerrarla.
final moveSessionProvider = NotifierProvider.autoDispose
    .family<MoveSessionController, MoveSessionState, MoveSessionArgs>(
      MoveSessionController.new,
    );

/// La sesión que se mueve y la fecha con que abre la hoja (null: la de
/// ahora, hasta que Evelyn elija otra).
typedef MoveSessionArgs = ({String sessionId, CalendarDate? date});

/// El dryRun de la fecha y la hora que hay en la hoja.
enum MoveChecksStatus {
  /// No se pidió (la misma fecha y hora de ahora).
  idle,
  loading,
  ready,

  /// No se pudo pedir: se puede mover igual (el servidor vuelve a comprobar)
  /// y reintentar.
  failed,
}

/// Lo que impide mover la sesión, en el orden de la hoja.
enum MoveBlocker {
  /// La misma fecha y la misma hora de ahora.
  unchanged,

  /// Esa semana ya tiene otra sesión de la reserva.
  weekTaken,

  /// Choca con otra sesión.
  clash,
}

/// Fallas después de las cuales la hoja ya no puede mover nada.
const Set<SessionFailureKind> _blockingFailures = {
  SessionFailureKind.notMovable,
  SessionFailureKind.notFound,
  SessionFailureKind.forbidden,
  SessionFailureKind.unauthorized,
};

/// Lo que devuelve la hoja al mover: la sesión movida y la fecha y la hora de
/// antes, para «Deshacer».
typedef MoveOutcome = ({
  CookingSession moved,
  CalendarDate previousDate,
  ClockTime previousStart,
});

@Freezed(toStringOverride: false)
abstract class MoveSessionState with _$MoveSessionState {
  const factory MoveSessionState({
    /// Hoy en Roma, al abrir la hoja.
    required CalendarDate today,

    /// La sesión al abrir la hoja; null si no se encontró.
    CookingSession? session,

    /// Las semanas de su reserva (para «Pasar al final»).
    @Default(<CookingSession>[]) List<CookingSession> booking,
    required CalendarDate date,
    required ClockTime start,

    /// La eligió Evelyn: deja de ser la de ahora.
    @Default(false) bool startEdited,

    /// La primera llegada de la fecha elegida, según el servidor.
    ClockTime? suggestedStart,
    @Default(MoveChecksStatus.idle) MoveChecksStatus checksStatus,

    /// El último dryRun.
    MoveSessionResult? check,

    /// Fecha y hora de [check] (ver [inputKey]).
    String? checksKey,
    @Default(false) bool sending,
    SessionFailure? failure,

    /// La sesión movida.
    MoveOutcome? outcome,
  }) = _MoveSessionState;

  const MoveSessionState._();

  /// Fecha y hora: lo que decide el dryRun.
  String get inputKey => '${date.toIso()}|${start.toHhMm()}';

  /// Otra fecha u otra hora que las de ahora.
  bool get changed =>
      session != null && (date != session!.date || start != session!.start);

  bool get checksCurrent =>
      checksKey == inputKey &&
      (checksStatus == MoveChecksStatus.ready ||
          checksStatus == MoveChecksStatus.failed);

  /// Lo que dijo el servidor de lo que hay ahora en la hoja.
  MoveSessionResult? get currentCheck =>
      checksCurrent && checksStatus == MoveChecksStatus.ready ? check : null;

  bool get clash => currentCheck?.status.blocksBooking ?? false;

  bool get weekTaken => currentCheck?.weekTaken ?? false;

  /// «Pasar al final de la reserva»: la semana después de la última; null si
  /// ya es la última (o no hay sesión).
  CalendarDate? get endOfBooking {
    final current = session;
    return current == null ? null : endOfBookingDate(current, booking);
  }

  /// Ya no puede mover nada (la sesión cambió, no existe o no hay permiso).
  bool get blocked =>
      session == null ||
      (failure != null && _blockingFailures.contains(failure!.kind));

  bool get canConfirm =>
      outcome == null &&
      !sending &&
      !blocked &&
      changed &&
      checksCurrent &&
      !clash &&
      !weekTaken;

  /// Lo primero que impide moverla; null si nada (o mientras el dryRun no
  /// volvió).
  MoveBlocker? get blocker {
    if (blocked) return null;
    if (!changed) return MoveBlocker.unchanged;
    if (weekTaken) return MoveBlocker.weekTaken;
    if (clash) return MoveBlocker.clash;
    return null;
  }

  @override
  String toString() =>
      'MoveSessionState(checks: ${checksStatus.name}, sending: $sending, '
      'failure: ${failure?.kind.name}, done: ${outcome != null})';
}

class MoveSessionController extends Notifier<MoveSessionState> {
  MoveSessionController(this.args);

  final MoveSessionArgs args;

  /// Cada dryRun suma uno: solo vale la respuesta del último.
  int _checksSeq = 0;

  SessionsRepository get _repository => ref.read(sessionsRepositoryProvider);

  @override
  MoveSessionState build() {
    final today = romeToday(ref.read(clockProvider)());
    // Se lee una vez: la hoja no se rehace si la ficha cambia mientras tanto.
    // La pantalla la abre con la ficha ya cargada.
    final detail = ref.read(sessionDetailProvider(args.sessionId)).value;
    final session = detail?.session;
    if (session == null || !session.canMove) {
      return MoveSessionState(
        today: today,
        session: session,
        date: args.date ?? session?.date ?? today,
        start: session?.start ?? defaultBookingArrival,
        failure: SessionFailure(
          session == null
              ? SessionFailureKind.notFound
              : SessionFailureKind.notMovable,
          status: session?.status,
        ),
      );
    }
    final initial = MoveSessionState(
      today: today,
      session: session,
      booking: detail!.booking,
      date: args.date ?? session.date,
      start: session.start,
    );
    if (initial.changed) {
      scheduleMicrotask(() {
        if (ref.mounted) unawaited(_runChecks());
      });
    }
    return initial;
  }

  /// Mientras se mueve, o ya movida, la hoja no cambia.
  bool get _locked => state.sending || state.outcome != null || state.blocked;

  /// La fecha nueva.
  void setDate(CalendarDate date) {
    if (_locked || date == state.date) return;
    _edit(state.copyWith(date: date));
    unawaited(_runChecks());
  }

  /// La hora de llegada que eligió Evelyn.
  void setStart(ClockTime start) {
    if (_locked || start == state.start) return;
    _edit(state.copyWith(start: start, startEdited: true));
    unawaited(_runChecks());
  }

  /// «Pasar al final de la reserva»: la semana después de la última.
  void moveToEnd() {
    final end = state.endOfBooking;
    if (end != null) setDate(end);
  }

  /// Vuelve a pedir el dryRun (después de una falla).
  void retryChecks() {
    if (_locked) return;
    unawaited(_runChecks());
  }

  /// Mueve la sesión. No hace nada si no se puede ([canConfirm]). Si falla,
  /// queda en [MoveSessionState.failure] y se puede reintentar.
  Future<void> confirm() async {
    final current = state;
    final session = current.session;
    if (!current.canConfirm || session == null) return;
    state = current.copyWith(sending: true, failure: null);
    try {
      final moved = await ref
          .read(sessionCommandsProvider)
          .move(session, date: current.date, start: current.start);
      if (!ref.mounted) return;
      state = state.copyWith(
        sending: false,
        outcome: (
          moved: moved,
          previousDate: session.date,
          previousStart: session.start,
        ),
      );
    } on SessionFailure catch (failure) {
      if (!ref.mounted) return;
      state = state.copyWith(sending: false, failure: failure);
      switch (failure.kind) {
        case SessionFailureKind.slotTaken ||
            SessionFailureKind.weekTaken ||
            SessionFailureKind.conflict:
          // El dryRun marca por qué.
          unawaited(_runChecks());
        case SessionFailureKind.notMovable || SessionFailureKind.notFound:
          // Cambió en otro dispositivo: la ficha lo muestra al volver.
          unawaited(
            ref
                .read(sessionDetailProvider(session.id).notifier)
                .reloadQuietly(),
          );
        case _:
          break;
      }
    }
  }

  /// Un cambio de Evelyn: la falla de un intento anterior ya no vale.
  void _edit(MoveSessionState next) {
    state = next.failure == null || next.blocked
        ? next
        : next.copyWith(failure: null);
  }

  Future<void> _runChecks() async {
    final seq = ++_checksSeq;
    final current = state;
    final session = current.session;
    if (session == null || current.blocked || current.outcome != null) return;
    if (!current.changed) {
      state = current.copyWith(
        checksStatus: MoveChecksStatus.idle,
        check: null,
        checksKey: null,
      );
      return;
    }
    state = current.copyWith(checksStatus: MoveChecksStatus.loading);
    try {
      final check = await _repository.moveSession(
        MoveSessionRequest(
          sessionId: session.id,
          date: current.date,
          start: current.start,
          dryRun: true,
        ),
      );
      if (!ref.mounted || seq != _checksSeq) return;
      state = state.copyWith(
        check: check,
        suggestedStart: check.suggestedStart,
        checksStatus: MoveChecksStatus.ready,
        checksKey: current.inputKey,
      );
    } on SessionFailure catch (failure) {
      if (!ref.mounted || seq != _checksSeq) return;
      if (_blockingFailures.contains(failure.kind)) {
        state = state.copyWith(
          failure: failure,
          checksStatus: MoveChecksStatus.idle,
          check: null,
        );
        if (failure.kind == SessionFailureKind.notMovable ||
            failure.kind == SessionFailureKind.notFound) {
          unawaited(
            ref
                .read(sessionDetailProvider(session.id).notifier)
                .reloadQuietly(),
          );
        }
        return;
      }
      // Sin respuesta: se puede mover igual (el servidor vuelve a comprobar).
      state = state.copyWith(
        checksStatus: MoveChecksStatus.failed,
        check: null,
        checksKey: current.inputKey,
      );
    }
  }
}

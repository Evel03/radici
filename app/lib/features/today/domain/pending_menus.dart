// «Menús para mandar» en Hoy (SPEC 5.8, pasos 5 a 8; §7): las semanas de los
// próximos días que esperan algo de Evelyn con su menú. Dart puro.
//
// Entran las semanas confirmadas de una reserva (una sesión con pedido, que
// todavía se arma: confirmed o una vieja en shopping_done) de hoy y los 6
// días siguientes (los 7 de la tira, días de Roma) que todavía no empezaron,
// cuyo menú no tiene platos, no se mandó, cambió después de mandarlo o
// recibió un pedido de cambios de la clienta en su último envío. El menú se
// manda hasta 48 h antes de la llegada (desde ahí los avisos por email a
// Evelyn pasan a cada 2 horas, SPEC 5.8 paso 8): el límite se resalta cuando
// faltan menos de 24 h o ya pasó.
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';
import 'package:radici/features/today/domain/today.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

/// El límite para mandar el menú de una semana: tantas horas antes de la
/// llegada.
const Duration menuSendDeadline = Duration(hours: 48);

/// Desde cuánto antes del límite se resalta.
const Duration menuDeadlineWarning = Duration(hours: 24);

/// Qué le falta al menú de una semana.
enum PendingMenuState {
  /// No tiene menú guardado, o lo tiene sin platos.
  noMenu,

  /// Tiene menú guardado, pero nunca salió.
  notSent,

  /// Salió, pero el menú cambió después: la clienta tiene el de antes.
  changedSinceSent,

  /// La clienta pidió cambios en el último envío.
  changesRequested,
}

/// Una semana que espera algo de Evelyn con su menú.
final class PendingMenu {
  const PendingMenu({
    required this.session,
    required this.state,
    required this.deadline,
    this.position,
  });

  final CookingSession session;
  final PendingMenuState state;

  /// El límite para mandarlo: [menuSendDeadline] antes de la llegada.
  final DateTime deadline;

  /// «Semana k de N» (null en una reserva de una sola semana).
  final BookingWeekPosition? position;

  /// El límite ya pasó en [now].
  bool deadlinePassed(DateTime now) => !now.isBefore(deadline);

  /// El límite ya pasó o faltan menos de [menuDeadlineWarning]: se resalta.
  bool deadlineNear(DateTime now) =>
      !now.isBefore(deadline.subtract(menuDeadlineWarning));

  @override
  bool operator ==(Object other) =>
      other is PendingMenu &&
      other.session == session &&
      other.state == state &&
      other.deadline == deadline &&
      other.position == position;

  @override
  int get hashCode => Object.hash(session, state, deadline, position);

  /// Solo la sesión y el estado: nada de la clienta.
  @override
  String toString() => 'PendingMenu(${session.id}, ${state.name})';
}

/// Instante de la llegada de [session] (su día y su hora, de Roma).
DateTime sessionArrival(CookingSession session) =>
    romeInstant(session.date, session.times.arrival);

/// El límite para mandar el menú de [session]: [menuSendDeadline] antes de
/// su llegada.
DateTime menuDeadlineOf(CookingSession session) =>
    sessionArrival(session).subtract(menuSendDeadline);

/// Las semanas que pueden esperar su menú: de [sessions], las confirmadas de
/// una reserva (con pedido; held, la de un presupuesto enviado, todavía no
/// es una reserva) de [today] y los días siguientes de la tira
/// ([todayWindowDays] en total), por fecha y llegada. Las que ya empezaron
/// se descartan con la hora ([pendingMenus]).
List<CookingSession> pendingMenuCandidates(
  Iterable<CookingSession> sessions, {
  required CalendarDate today,
}) {
  final until = today.addDays(todayWindowDays - 1);
  return [
    for (final session in sessions)
      if (session.status.shown == SessionStatus.confirmed &&
          isMenuSendable(session) &&
          !session.date.isBefore(today) &&
          !session.date.isAfter(until))
        session,
  ]..sort(compareSessions);
}

/// Qué le falta al menú de una semana, con su menú ([summary]) y su último
/// envío que salió ([send]); null si nada (salió, sin cambios después, y la
/// clienta no pidió cambios).
PendingMenuState? pendingMenuState(
  WeekMenuSummary summary,
  MenuSendRecord? send,
) {
  if (send == null) {
    return summary.saved && summary.dishes > 0
        ? PendingMenuState.notSent
        : PendingMenuState.noMenu;
  }
  if (send.changesRequestedAt != null) {
    return PendingMenuState.changesRequested;
  }
  final version = summary.version;
  if (version != null && version > send.menuVersion) {
    return PendingMenuState.changedSinceSent;
  }
  return null;
}

/// Las semanas que esperan algo de Evelyn con su menú, por fecha y llegada:
/// de [candidates] ([pendingMenuCandidates]), las que todavía no empezaron
/// en [now] y a las que les falta algo ([pendingMenuState]), con su menú
/// ([summaries]; sin fila, como sin menú), su último envío ([sends]) y su
/// lugar en la reserva ([positions]).
List<PendingMenu> pendingMenus(
  Iterable<CookingSession> candidates, {
  required Map<String, WeekMenuSummary> summaries,
  required Map<String, MenuSendRecord> sends,
  required Map<String, BookingWeekPosition> positions,
  required DateTime now,
}) {
  final sorted = candidates.toList()..sort(compareSessions);
  return [
    for (final session in sorted)
      if (sessionArrival(session).isAfter(now))
        if (pendingMenuState(
              summaries[session.id] ?? const WeekMenuSummary(),
              sends[session.id],
            )
            case final state?)
          PendingMenu(
            session: session,
            state: state,
            deadline: menuDeadlineOf(session),
            position: positions[session.id],
          ),
  ];
}

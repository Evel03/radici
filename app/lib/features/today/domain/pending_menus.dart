// «Menús para mandar» en Hoy (SPEC 5.8, pasos 5 a 8; §7): las semanas de los
// próximos días que esperan algo de Evelyn con su menú. Dart puro.
//
// Entran las semanas confirmadas de una reserva (una sesión con pedido, que
// todavía se arma: confirmed o una vieja en shopping_done) y la semana 1 de
// un presupuesto sin aceptar (su menú sale con él) de hoy y los 6
// días siguientes (los 7 de la tira, días de Roma) que todavía no empezaron,
// cuyo menú no tiene platos, no se mandó, cambió después de mandarlo o
// recibió un pedido de cambios de la clienta en su último envío; una
// confirmada, también si su último envío salió con una versión anterior del
// presupuesto que nadie confirmó (como los avisos de la base,
// menu_reminders_due). El menú se manda hasta 48 h antes de la llegada (desde
// ahí los avisos por email a Evelyn pasan a cada 2 horas, SPEC 5.8 paso 8);
// la semana 1 de un presupuesto, además, antes de que venza su plazo
// (hold_until: el borrador a las 24 h, mandado a las 48 h del último envío),
// si es antes. El límite se resalta cuando faltan menos de 24 h o ya pasó.
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

  /// El último envío salió con una versión anterior del presupuesto (otro
  /// envío lo llevó después, desde otra semana) y nadie lo confirmó: para los
  /// avisos sigue pendiente, como si no hubiera salido.
  sentWithEarlierQuote,
}

/// Una semana que espera algo de Evelyn con su menú.
final class PendingMenu {
  const PendingMenu({
    required this.session,
    required this.state,
    required this.deadline,
    this.position,
    this.quoteExpires = false,
  });

  final CookingSession session;
  final PendingMenuState state;

  /// El límite para mandarlo: [menuSendDeadline] antes de la llegada o, en
  /// la semana 1 de un presupuesto, su plazo si es antes ([quoteExpires]).
  final DateTime deadline;

  /// «Semana k de N» (null en una reserva de una sola semana).
  final BookingWeekPosition? position;

  /// [deadline] es el plazo del presupuesto (`hold_until`), no el del menú:
  /// si para entonces no salió (o la clienta no lo aceptó), vence y las
  /// fechas se liberan.
  final bool quoteExpires;

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
      other.position == position &&
      other.quoteExpires == quoteExpires;

  @override
  int get hashCode =>
      Object.hash(session, state, deadline, position, quoteExpires);

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

/// El límite de [session] y si es el plazo de su presupuesto: el del menú
/// ([menuDeadlineOf]) o, en una semana retenida (la 1 de un presupuesto sin
/// aceptar) con plazo [hold], ese plazo si es antes.
({DateTime deadline, bool quoteExpires}) pendingDeadlineOf(
  CookingSession session, {
  DateTime? hold,
}) {
  final menu = menuDeadlineOf(session);
  if (session.status == SessionStatus.held &&
      hold != null &&
      hold.isBefore(menu)) {
    return (deadline: hold, quoteExpires: true);
  }
  return (deadline: menu, quoteExpires: false);
}

/// Las semanas que pueden esperar su menú: de [sessions], las confirmadas de
/// una reserva (con pedido) y la semana 1 de un presupuesto sin aceptar
/// (held: su menú sale con él; las demás semanas del presupuesto salen
/// después de que lo acepte), de [today] y los días siguientes de la tira
/// ([todayWindowDays] en total), por fecha y llegada. Las que ya empezaron
/// se descartan con la hora ([pendingMenus]).
List<CookingSession> pendingMenuCandidates(
  Iterable<CookingSession> sessions, {
  required CalendarDate today,
}) {
  final until = today.addDays(todayWindowDays - 1);
  final all = sessions.toList();
  return [
    for (final session in all)
      if ((session.status.shown == SessionStatus.confirmed ||
              quoteWeekRole(session, all) == QuoteWeekRole.first) &&
          isMenuSendable(session) &&
          !session.date.isBefore(today) &&
          !session.date.isAfter(until))
        session,
  ]..sort(compareSessions);
}

/// Qué le falta al menú de una semana, con su menú ([summary]) y su último
/// envío que salió ([send]); null si nada (salió, sin cambios después, y la
/// clienta no pidió cambios). [sentWithEarlierQuote]: ese envío salió con una
/// versión anterior del presupuesto que nadie confirmó (la semana sigue
/// pendiente, como en los avisos).
PendingMenuState? pendingMenuState(
  WeekMenuSummary summary,
  MenuSendRecord? send, {
  bool sentWithEarlierQuote = false,
}) {
  if (send == null) {
    return summary.saved && summary.dishes > 0
        ? PendingMenuState.notSent
        : PendingMenuState.noMenu;
  }
  if (send.changesRequestedAt != null) {
    return PendingMenuState.changesRequested;
  }
  if (sentWithEarlierQuote) return PendingMenuState.sentWithEarlierQuote;
  final version = summary.version;
  if (version != null && version > send.menuVersion) {
    return PendingMenuState.changedSinceSent;
  }
  return null;
}

/// Las semanas que esperan algo de Evelyn con su menú, por fecha y llegada:
/// de [candidates] ([pendingMenuCandidates]), las que todavía no empezaron
/// en [now] y a las que les falta algo ([pendingMenuState]), con su menú
/// ([summaries]; sin fila, como sin menú), su último envío ([sends]), su
/// lugar en la reserva ([positions]), el plazo del presupuesto abierto de
/// cada pedido ([quoteHolds], para la semana 1 retenida) y el último envío
/// que salió con cada presupuesto ([quoteSends], para una semana confirmada
/// cuyo último envío lo llevaba: sentWithEarlierQuote).
List<PendingMenu> pendingMenus(
  Iterable<CookingSession> candidates, {
  required Map<String, WeekMenuSummary> summaries,
  required Map<String, MenuSendRecord> sends,
  required Map<String, BookingWeekPosition> positions,
  required DateTime now,
  Map<String, DateTime> quoteHolds = const {},
  Map<String, MenuSendRecord> quoteSends = const {},
}) {
  final sorted = candidates.toList()..sort(compareSessions);
  return [
    for (final session in sorted)
      if (sessionArrival(session).isAfter(now))
        ?_pendingMenu(
          session,
          summary: summaries[session.id] ?? const WeekMenuSummary(),
          send: sends[session.id],
          position: positions[session.id],
          hold: quoteHolds[session.requestId],
          quoteSends: quoteSends,
        ),
  ];
}

/// Lo que le falta a [session], con su límite; null si nada.
PendingMenu? _pendingMenu(
  CookingSession session, {
  required WeekMenuSummary summary,
  required MenuSendRecord? send,
  required BookingWeekPosition? position,
  required DateTime? hold,
  required Map<String, MenuSendRecord> quoteSends,
}) {
  // La regla de menu_reminders_due solo mira las semanas confirmadas.
  final quoteId = send?.quoteId;
  final earlierQuote =
      send != null &&
      quoteId != null &&
      session.status.shown == SessionStatus.confirmed &&
      sentWithEarlierQuote(send, quoteSends[quoteId]);
  final state = pendingMenuState(
    summary,
    send,
    sentWithEarlierQuote: earlierQuote,
  );
  if (state == null) return null;
  final (:deadline, :quoteExpires) = pendingDeadlineOf(session, hold: hold);
  return PendingMenu(
    session: session,
    state: state,
    deadline: deadline,
    position: position,
    quoteExpires: quoteExpires,
  );
}

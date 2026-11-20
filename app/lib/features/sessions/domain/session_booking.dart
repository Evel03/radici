// Reglas de las sesiones de una reserva y de la agenda: «Semana k de N», las
// semanas siguientes, el final de la reserva, qué ofrecer si una semana que se
// quiso cancelar ya está cobrada, la próxima sesión viva de la misma ficha,
// las sesiones de cada día y desde qué día las lee la agenda. Dart puro.
//
// Una reserva es un pedido aceptado más sus sesiones, como mucho una viva por
// semana (`sessions_una_por_semana`). Las canceladas no cuentan.
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

/// La semana [week] de [weeks] (desde 1) de una reserva.
typedef BookingWeekPosition = ({int week, int weeks});

/// Las sesiones vivas de la reserva de [session] en [booking], por fecha y
/// llegada.
List<CookingSession> liveBookingSessions(
  CookingSession session,
  Iterable<CookingSession> booking,
) {
  final requestId = session.requestId;
  if (requestId == null) return session.isLive ? [session] : const [];
  final live = <String, CookingSession>{
    for (final other in booking)
      if (other.requestId == requestId && other.isLive) other.id: other,
    if (session.isLive) session.id: session,
  };
  return live.values.toList()..sort(compareSessions);
}

/// «Semana k de N» de [session] entre las sesiones de su reserva, sin contar
/// las canceladas. null si está cancelada, si no tiene reserva o si la reserva
/// es de una sola semana.
BookingWeekPosition? bookingPosition(
  CookingSession session,
  Iterable<CookingSession> booking,
) {
  if (!session.isLive || session.requestId == null) return null;
  final live = liveBookingSessions(session, booking);
  if (live.length < 2) return null;
  final index = live.indexWhere((other) => other.id == session.id);
  return (week: index + 1, weeks: live.length);
}

/// Las semanas de la reserva después de [session] que todavía se pueden
/// cancelar (held, confirmed o shopping_done), por fecha.
List<CookingSession> followingSessions(
  CookingSession session,
  Iterable<CookingSession> booking,
) => [
  for (final other in liveBookingSessions(session, booking))
    if (other.id != session.id &&
        compareSessions(other, session) > 0 &&
        other.canCancel)
      other,
];

/// «Pasar al final de la reserva»: la semana después de la última de las otras
/// sesiones vivas de su reserva, el mismo día de la semana que esa última
/// (una sesión por semana). null si [session] ya es la última o no tiene otras.
CalendarDate? endOfBookingDate(
  CookingSession session,
  Iterable<CookingSession> booking,
) {
  final others = [
    for (final other in liveBookingSessions(session, booking))
      if (other.id != session.id) other,
  ];
  if (others.isEmpty) return null;
  final last = others.last.date;
  if (!last.isAfter(session.date)) return null;
  return last.addDays(7);
}

/// Qué ofrecer después de un 409 hasPayments al cancelar (no se canceló
/// nada): [paid], las pedidas que ya están cobradas, y [unpaid], las demás,
/// por fecha; [moveToEnd], la fecha para pasar la sesión de la ficha al final
/// de la reserva, o null.
typedef HasPaymentsPlan = ({
  List<CookingSession> paid,
  List<CookingSession> unpaid,
  CalendarDate? moveToEnd,
});

/// El plan después de cancelar [requested] (las sesiones que se mandaron, la
/// de la ficha [current] primero) cuando el servidor dijo que [paidIds] ya
/// están cobradas. Si ninguna de [paidIds] está entre las pedidas (o no vino
/// ninguna), se toman todas como cobradas: nunca se ofrece repetir lo mismo.
///
/// - «Pasar al final» (decisión 5 del plan) solo si se cancelaba únicamente
///   [current], está cobrada y se puede mover: con «también las siguientes»,
///   el final de la reserva cuenta las semanas que se querían cancelar.
/// - [HasPaymentsPlan.unpaid] solo si se cancelaba más de una: «cancelar solo
///   las no cobradas».
HasPaymentsPlan hasPaymentsPlan({
  required CookingSession current,
  required Iterable<CookingSession> booking,
  required List<CookingSession> requested,
  required List<String> paidIds,
}) {
  final requestedIds = {for (final session in requested) session.id};
  final reported = paidIds.toSet().intersection(requestedIds);
  final paidSet = reported.isEmpty ? requestedIds : reported;
  final sorted = [...requested]..sort(compareSessions);
  final paid = [
    for (final session in sorted)
      if (paidSet.contains(session.id)) session,
  ];
  final onlyCurrent =
      requested.length == 1 && requested.single.id == current.id;
  return (
    paid: paid,
    unpaid: onlyCurrent
        ? const []
        : [
            for (final session in sorted)
              if (!paidSet.contains(session.id)) session,
          ],
    moveToEnd:
        onlyCurrent && paidSet.contains(current.id) && current.canMove
        ? endOfBookingDate(current, booking)
        : null,
  );
}

/// [session] es la última sesión viva de una reserva semanal (donde va
/// «Rinnova», decisión 3): está viva (también cocinada o cobrada), su pedido
/// embebido está aceptado y es semanal, y ninguna otra viva de [booking] va
/// después. No un presupuesto enviado, una sesión extra ni una sin pedido.
bool isLastLiveOfWeeklyBooking(
  CookingSession session,
  Iterable<CookingSession> booking,
) {
  final request = session.request;
  if (!session.isLive ||
      request == null ||
      !request.isBooking ||
      request.type != RequestType.week) {
    return false;
  }
  return liveBookingSessions(session, booking).last.id == session.id;
}

/// La primera (por [compareSessions]) de las otras sesiones vivas de la misma
/// ficha que [last] que van después de ella, de cualquier pedido (una
/// renovación, otra reserva o una sesión suelta); null si no hay. Compara por
/// ficha: dos fichas de la misma persona no se ven como una.
CookingSession? nextLiveSessionOfClient(
  CookingSession last,
  Iterable<CookingSession> sessions,
) {
  CookingSession? next;
  for (final other in sessions) {
    if (other.id == last.id ||
        !other.isLive ||
        other.clientId != last.clientId ||
        compareSessions(other, last) <= 0) {
      continue;
    }
    if (next == null || compareSessions(other, next) < 0) next = other;
  }
  return next;
}

/// La ficha de [last] tiene otra sesión viva después de ella (ver
/// [nextLiveSessionOfClient]).
bool hasLaterLiveSession(
  CookingSession last,
  Iterable<CookingSession> sessions,
) => nextLiveSessionOfClient(last, sessions) != null;

/// Por fecha, después por llegada y por id (un orden estable).
int compareSessions(CookingSession a, CookingSession b) {
  final byDate = a.date.compareTo(b.date);
  if (byDate != 0) return byDate;
  final byStart = a.start.compareTo(b.start);
  return byStart != 0 ? byStart : a.id.compareTo(b.id);
}

/// Las sesiones vivas de [sessions] agrupadas por día y ordenadas por llegada.
Map<CalendarDate, List<CookingSession>> sessionsByDate(
  Iterable<CookingSession> sessions,
) {
  final byDate = <CalendarDate, List<CookingSession>>{};
  for (final session in sessions) {
    if (!session.isLive) continue;
    (byDate[session.date] ??= []).add(session);
  }
  for (final list in byDate.values) {
    list.sort(compareSessions);
  }
  return byDate;
}

/// Días antes y después de la última sesión viva de una reserva en que Hoy la
/// muestra entre las que terminan. Va acá porque también decide desde qué día
/// lee la agenda ([sessionsWindowFrom]).
const int endingBookingNoticeDays = 7;

/// Desde qué día lee la agenda las sesiones: el lunes de la primera semana
/// del mes de [today], [endingBookingNoticeDays] días antes de [today] (así
/// Hoy tiene las reservas que terminaron hace hasta 7 días) o el lunes de la
/// primera semana del mes de [selected] (el día elegido), el que sea antes.
/// Hacia adelante no hay tope: las reservas son de 8 semanas como mucho.
CalendarDate sessionsWindowFrom({
  required CalendarDate today,
  required CalendarDate selected,
}) {
  final candidates = [
    today.firstOfMonth.startOfWeek,
    today.addDays(-endingBookingNoticeDays),
    selected.firstOfMonth.startOfWeek,
  ];
  return candidates.reduce((a, b) => b.isBefore(a) ? b : a);
}

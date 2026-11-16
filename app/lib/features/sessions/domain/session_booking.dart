// Reglas de las sesiones de una reserva y de la agenda: «Semana k de N», las
// semanas siguientes, el final de la reserva, las sesiones de cada día y desde
// qué día las lee la agenda. Dart puro.
//
// Una reserva es un pedido aceptado más sus sesiones, como mucho una viva por
// semana (`sessions_una_por_semana`). Las canceladas no cuentan.
import 'package:radici/core/rome_time.dart';
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

/// Desde qué día lee la agenda las sesiones: el lunes de la primera semana
/// del mes de [today] o del de [selected] (el día elegido), el que sea antes.
/// Hacia adelante no hay tope: las reservas son de 8 semanas como mucho.
CalendarDate sessionsWindowFrom({
  required CalendarDate today,
  required CalendarDate selected,
}) {
  final current = today.firstOfMonth.startOfWeek;
  final shown = selected.firstOfMonth.startOfWeek;
  return shown.isBefore(current) ? shown : current;
}

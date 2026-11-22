// Resumen de un día de la agenda, para el cartel de su celda en el mes (al
// pasar el mouse o al mantenerla apretada): de cada sesión, la clienta, las
// horas, «Semana k de N», las personas, el estado y la zona; de cada pedido
// que prefería el día, el cliente, el tipo y el estado. Dart puro.
//
// El cartel se puede ver por encima del hombro: el resumen solo lleva eso.
// Nada de alergias, dirección, teléfono ni notas (están en la ficha).
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

/// Cuántos elementos (sesiones y pedidos) muestra como mucho el cartel; los
/// demás solo se cuentan («e altre 2»).
const int agendaSummaryMaxItems = 4;

/// Un elemento del cartel.
sealed class AgendaSummaryItem {
  const AgendaSummaryItem();

  /// La clienta o el cliente.
  String get name;
}

/// Una sesión viva del día.
final class AgendaSessionSummary extends AgendaSummaryItem {
  const AgendaSessionSummary({
    required this.sessionId,
    required this.name,
    required this.arrival,
    required this.end,
    required this.status,
    this.week,
    this.people,
    this.zone,
  });

  /// Lo que el cartel muestra de [session]; [week], su «Semana k de N».
  AgendaSessionSummary.of(CookingSession session, {this.week})
    : sessionId = session.id,
      name = session.displayName,
      arrival = session.times.arrival,
      end = session.times.end,
      status = session.status.shown,
      people = session.people,
      zone = session.zone;

  final String sessionId;

  @override
  final String name;

  /// Llegada y fin de la cocina, en minutos desde la medianoche de Roma
  /// (SessionTimes).
  final int arrival;
  final int end;

  /// Como se muestra (SessionStatus.shown): una vieja en shopping_done, como
  /// confirmada.
  final SessionStatus status;

  /// «Semana k de N»; null si la reserva es de una sola semana, si no tiene
  /// reserva o si la agenda no leyó todas sus semanas (ver agendaDaySummary).
  final BookingWeekPosition? week;
  final int? people;
  final String? zone;

  @override
  bool operator ==(Object other) =>
      other is AgendaSessionSummary &&
      other.sessionId == sessionId &&
      other.name == name &&
      other.arrival == arrival &&
      other.end == end &&
      other.status == status &&
      other.week == week &&
      other.people == people &&
      other.zone == zone;

  @override
  int get hashCode =>
      Object.hash(sessionId, name, arrival, end, status, week, people, zone);

  /// Solo el id: nada de la clienta.
  @override
  String toString() => 'AgendaSessionSummary($sessionId)';
}

/// Un pedido que prefería el día y todavía no es una reserva.
final class AgendaRequestSummary extends AgendaSummaryItem {
  const AgendaRequestSummary({
    required this.requestId,
    required this.name,
    required this.type,
    required this.status,
    required this.seen,
  });

  /// Lo que el cartel muestra de [request].
  AgendaRequestSummary.of(ChefRequest request)
    : requestId = request.id,
      name = request.client.displayName,
      type = request.type,
      status = request.status,
      seen = request.seenAt != null;

  final String requestId;

  @override
  final String name;
  final RequestType type;
  final RequestStatus status;

  /// La cocinera ya lo abrió: uno nuevo se ve como «Vista».
  final bool seen;

  @override
  bool operator ==(Object other) =>
      other is AgendaRequestSummary &&
      other.requestId == requestId &&
      other.name == name &&
      other.type == type &&
      other.status == status &&
      other.seen == seen;

  @override
  int get hashCode => Object.hash(requestId, name, type, status, seen);

  /// Solo el id: nada del cliente.
  @override
  String toString() => 'AgendaRequestSummary($requestId)';
}

/// El cartel de un día: [items] en orden (primero las sesiones, por llegada;
/// después los pedidos, en el orden de la agenda) y [more], los que no
/// entran.
final class AgendaDaySummary {
  const AgendaDaySummary({required this.items, this.more = 0});

  /// Un día sin sesiones ni pedidos: sin cartel.
  static const AgendaDaySummary empty = AgendaDaySummary(items: []);

  final List<AgendaSummaryItem> items;
  final int more;

  bool get isEmpty => items.isEmpty;

  @override
  bool operator ==(Object other) {
    if (other is! AgendaDaySummary ||
        other.more != more ||
        other.items.length != items.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      if (other.items[i] != items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(more, Object.hashAll(items));

  /// Solo cuántos: nada de las clientas.
  @override
  String toString() => 'AgendaDaySummary(${items.length}, more: $more)';
}

/// El cartel de un día con lo que la agenda ya leyó: [sessions], las del día
/// (salen las vivas, por llegada); [requests], los pedidos que lo preferían,
/// en el orden de la agenda (salen los activos); y [loaded], todas las
/// sesiones de la agenda, de todos los estados, para «Semana k de N». Como
/// mucho [maxItems] elementos, primero las sesiones.
///
/// La agenda lee las sesiones desde sessionsWindowFrom: de una reserva que
/// empezó antes le faltan las primeras semanas, y contar solo las que tiene
/// daría un número equivocado. Por eso «Semana k de N» sale solo si [loaded]
/// trae todas las semanas que se crearon (`requests.weeks`, que escribe
/// chef_create_booking; las canceladas siguen siendo filas); si no, el cartel
/// no lo dice (la ficha lo dice, con toda la reserva).
AgendaDaySummary agendaDaySummary({
  required Iterable<CookingSession> sessions,
  required Iterable<ChefRequest> requests,
  required Iterable<CookingSession> loaded,
  int maxItems = agendaSummaryMaxItems,
}) {
  assert(maxItems > 0, 'El cartel muestra al menos un elemento');
  final live = sessions.where((session) => session.isLive).toList()
    ..sort(compareSessions);
  final active = requests.where((request) => request.isActive).toList();
  final total = live.length + active.length;
  if (total == 0) return AgendaDaySummary.empty;
  final shownSessions = live.take(maxItems).toList();
  final items = <AgendaSummaryItem>[
    for (final session in shownSessions)
      AgendaSessionSummary.of(session, week: _weekOf(session, loaded)),
    for (final request in active.take(maxItems - shownSessions.length))
      AgendaRequestSummary.of(request),
  ];
  return AgendaDaySummary(items: items, more: total - items.length);
}

/// «Semana k de N» de [session] entre las sesiones de su reserva en
/// [loaded], solo si están todas (ver agendaDaySummary).
BookingWeekPosition? _weekOf(
  CookingSession session,
  Iterable<CookingSession> loaded,
) {
  final requestId = session.requestId;
  final created = session.request?.weeks;
  if (requestId == null || created == null) return null;
  final booking = [
    for (final other in loaded)
      if (other.requestId == requestId) other,
  ];
  final rows = {for (final other in booking) other.id, session.id};
  if (rows.length < created) return null;
  return bookingPosition(session, booking);
}

// Reglas de Hoy, el inicio de la cocinera: qué sesión se muestra, cuándo
// terminó una sesión, qué reservas terminan y la tira de 7 días. Dart puro.
//
// «Hoy» es el día de Roma: lo calcula romeTodayProvider (cambia a la
// medianoche de Roma) y cada función lo recibe. Una sesión viva es una que no
// está cancelada (como en la agenda).
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

/// Días de la tira de Hoy y de la ventana de las reservas que terminan: hoy y
/// los 6 siguientes.
const int todayWindowDays = 7;

/// Lo que Hoy muestra de las sesiones.
final class TodayFocus {
  const TodayFocus({required this.sessions, required this.isToday});

  /// Sin ninguna sesión viva desde hoy.
  static const TodayFocus empty = TodayFocus(sessions: [], isToday: false);

  /// Las de hoy (primero las que todavía no terminaron, por llegada; después
  /// las terminadas) o, si hoy no hay ninguna, la próxima. Vacía si no hay
  /// ninguna sesión viva desde hoy.
  final List<CookingSession> sessions;

  /// Son de hoy; si no, es la próxima, de otro día.
  final bool isToday;

  /// La de los botones de abajo («Cómo llegar» y WhatsApp): la próxima de hoy
  /// (o la que está en curso), o la próxima de otro día.
  CookingSession? get main => sessions.isEmpty ? null : sessions.first;

  @override
  bool operator ==(Object other) {
    if (other is! TodayFocus ||
        other.isToday != isToday ||
        other.sessions.length != sessions.length) {
      return false;
    }
    for (var i = 0; i < sessions.length; i++) {
      if (other.sessions[i] != sessions[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(isToday, Object.hashAll(sessions));

  /// Solo cuántas: nada de la clienta.
  @override
  String toString() => 'TodayFocus(${sessions.length}, isToday: $isToday)';
}

/// [session] ya terminó en el instante [now]: está cocinada o cobrada, o ya
/// pasó la hora en que termina la cocina (hora de Roma).
bool sessionFinished(CookingSession session, DateTime now) {
  if (session.status == SessionStatus.cooked ||
      session.status == SessionStatus.paid) {
    return true;
  }
  // Las dos en hora de pared de Roma (ver romeWallClock).
  final date = session.date;
  final end = DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).add(Duration(minutes: session.times.end));
  return !end.isAfter(romeWallClock(now));
}

/// Qué sesión muestra Hoy: todas las vivas de [today] (las que todavía no
/// terminaron en [now] primero, por llegada; después las terminadas) o, si
/// hoy no hay ninguna, la próxima viva (la más cercana). Las de días pasados
/// no cuentan aunque sigan confirmadas.
TodayFocus todayFocus(
  Iterable<CookingSession> sessions, {
  required CalendarDate today,
  required DateTime now,
}) {
  final live = [
    for (final session in sessions)
      if (session.isLive && !session.date.isBefore(today)) session,
  ]..sort(compareSessions);
  final ofToday = [
    for (final session in live)
      if (session.date == today) session,
  ];
  if (ofToday.isEmpty) {
    return live.isEmpty
        ? TodayFocus.empty
        : TodayFocus(sessions: [live.first], isToday: false);
  }
  return TodayFocus(
    sessions: [
      for (final session in ofToday)
        if (!sessionFinished(session, now)) session,
      for (final session in ofToday)
        if (sessionFinished(session, now)) session,
    ],
    isToday: true,
  );
}

/// Las reservas que terminan: las reservas semanales (un pedido semanal
/// aceptado más sus sesiones, SPEC §4; no un presupuesto enviado ni una sesión
/// extra) cuya última sesión viva cae entre [today] y los 6 días siguientes
/// (la ventana de la tira). Una que ya terminó (su última sesión es de un día
/// pasado) no cuenta, y tampoco una sesión sin su pedido embebido (no se sabe
/// qué es). Devuelve esa última sesión de cada una, por fecha.
List<CookingSession> endingBookings(
  Iterable<CookingSession> sessions, {
  required CalendarDate today,
}) {
  final last = <String, CookingSession>{};
  for (final session in sessions) {
    final requestId = session.requestId;
    if (requestId == null || !session.isLive || !_isWeeklyBooking(session)) {
      continue;
    }
    final current = last[requestId];
    if (current == null || compareSessions(session, current) > 0) {
      last[requestId] = session;
    }
  }
  final until = today.addDays(todayWindowDays - 1);
  return [
    for (final session in last.values)
      if (!session.date.isBefore(today) && !session.date.isAfter(until))
        session,
  ]..sort(compareSessions);
}

/// [session] es de una reserva semanal: su pedido (embebido) es semanal y
/// está aceptado.
bool _isWeeklyBooking(CookingSession session) {
  final request = session.request;
  return request != null &&
      request.isBooking &&
      request.type == RequestType.week;
}

/// Un día de la tira de Hoy.
final class TodayStripDay {
  const TodayStripDay({
    required this.date,
    required this.sessionCount,
    this.status,
    this.holiday,
  });

  final CalendarDate date;

  /// Sesiones vivas de ese día.
  final int sessionCount;

  /// Como en la agenda: abierto, bloqueado o sin horario (hoy nunca es
  /// pasado). null mientras no se sabe: la disponibilidad se está cargando o
  /// no se pudo cargar.
  final DayStatus? status;

  /// El feriado de ese día en Bergamo, si es uno.
  final ItalianHoliday? holiday;

  bool get isBlocked => status == DayStatus.blocked;

  @override
  bool operator ==(Object other) =>
      other is TodayStripDay &&
      other.date == date &&
      other.sessionCount == sessionCount &&
      other.status == status &&
      other.holiday == holiday;

  @override
  int get hashCode => Object.hash(date, sessionCount, status, holiday);

  @override
  String toString() =>
      'TodayStripDay(${date.toIso()}, $sessionCount, ${status?.name})';
}

/// La tira de Hoy: [today] y los 6 días siguientes, con las sesiones vivas de
/// cada uno ([sessionsByDate], ver la función del mismo nombre), su estado en
/// [availability] (null si todavía no se sabe) y su feriado, con las mismas
/// reglas que la agenda (dayStatus y bergamoHolidayOn).
List<TodayStripDay> todayStrip({
  required CalendarDate today,
  required Map<CalendarDate, List<CookingSession>> sessionsByDate,
  required AvailabilitySnapshot? availability,
}) => [
  for (var i = 0; i < todayWindowDays; i++)
    _stripDay(today.addDays(i), today, sessionsByDate, availability),
];

TodayStripDay _stripDay(
  CalendarDate day,
  CalendarDate today,
  Map<CalendarDate, List<CookingSession>> sessionsByDate,
  AvailabilitySnapshot? availability,
) => TodayStripDay(
  date: day,
  sessionCount: sessionsByDate[day]?.length ?? 0,
  status: availability == null
      ? null
      : dayStatus(day, today: today, availability: availability),
  holiday: bergamoHolidayOn(day),
);

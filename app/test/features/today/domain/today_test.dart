// Reglas de Hoy, el inicio de la cocinera: qué sesión se muestra (la de hoy,
// varias con la próxima primero, o la próxima de otro día; las canceladas
// nunca), cuándo terminó una sesión (en hora de Roma), qué reservas terminan
// (reservas semanales, no presupuestos: su última semana viva cae entre hoy y
// los 6 días siguientes) y la tira de 7 días con sus sesiones, bloqueos y
// feriados. "Hoy": martes 17/11/2026 (hora de invierno, UTC+1), salvo donde
// se dice otra cosa.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';
import 'package:radici/features/today/domain/today.dart';

import '../../../support/fakes.dart';
import '../../../support/session_fixtures.dart';

void main() {
  final today = CalendarDate(2026, 11, 17);

  /// Instante de [hour]:[minute] del 17/11 en Roma (UTC+1).
  DateTime rome(int hour, [int minute = 0]) =>
      DateTime.utc(2026, 11, 17, hour - 1, minute);

  CookingSession session(
    int n,
    CalendarDate date, {
    int hour = 10,
    SessionStatus status = SessionStatus.confirmed,
    String? requestId = bookingRequestId,
    RequestType type = RequestType.week,
    RequestStatus requestStatus = RequestStatus.accepted,
    int weeks = 4,
  }) => buildSession(
    n: n,
    date: date,
    start: ClockTime.hm(hour, 0),
    status: status,
    requestId: requestId,
    type: type,
    requestStatus: requestStatus,
    weeks: weeks,
  );

  List<String> ids(Iterable<CookingSession> sessions) => [
    for (final s in sessions) s.id,
  ];

  group('qué sesión se muestra', () {
    test('la de hoy, aunque haya otras después', () {
      final focus = todayFocus(
        [session(2, today.addDays(2)), session(1, today)],
        today: today,
        now: rome(8),
      );
      expect(focus.isToday, isTrue);
      expect(ids(focus.sessions), [sessionId(1)]);
      expect(focus.main?.id, sessionId(1));
    });

    test('sin sesión hoy, la próxima viva (la más cercana)', () {
      final focus = todayFocus(
        [session(3, today.addDays(3)), session(2, today.addDays(1))],
        today: today,
        now: rome(8),
      );
      expect(focus.isToday, isFalse);
      expect(ids(focus.sessions), [sessionId(2)]);
    });

    test('varias hoy: todas, por llegada mientras ninguna terminó', () {
      final focus = todayFocus(
        [session(2, today, hour: 15), session(1, today, hour: 9)],
        today: today,
        now: rome(8),
      );
      expect(focus.isToday, isTrue);
      expect(ids(focus.sessions), [sessionId(1), sessionId(2)]);
    });

    test('varias hoy: la que terminó pasa al final y la próxima queda primera', () {
      // La de las 10:00 cocina hasta las 13:00; la otra llega a las 16:00.
      final sessions = [session(1, today), session(2, today, hour: 16)];
      expect(
        ids(todayFocus(sessions, today: today, now: rome(12, 59)).sessions),
        [sessionId(1), sessionId(2)],
        reason: 'a las 12:59 sigue cocinando',
      );
      final afterwards = todayFocus(sessions, today: today, now: rome(13));
      expect(ids(afterwards.sessions), [sessionId(2), sessionId(1)]);
      expect(afterwards.main?.id, sessionId(2));
      // Cuáles terminaron: las del final.
      expect(afterwards.ongoing, 1);
      expect([for (var i = 0; i < 2; i++) afterwards.finishedAt(i)], [false, true]);
    });

    test('ninguna terminada mientras no pasa su hora; la próxima de otro día, tampoco', () {
      final sessions = [session(1, today), session(2, today, hour: 16)];
      final morning = todayFocus(sessions, today: today, now: rome(8));
      expect(morning.ongoing, 2);
      expect(morning.finishedAt(0), isFalse);
      expect(morning.finishedAt(1), isFalse);
      final evening = todayFocus(sessions, today: today, now: rome(20));
      expect(evening.ongoing, 0, reason: 'a las 20:00 terminaron las dos');
      final next = todayFocus(
        [session(3, today.addDays(1))],
        today: today,
        now: rome(20),
      );
      expect(next.finishedAt(0), isFalse);
      expect(TodayFocus.empty.ongoing, 0);
    });

    test('cocinada o cobrada cuenta como terminada aunque no haya pasado la hora', () {
      for (final status in [SessionStatus.cooked, SessionStatus.paid]) {
        final focus = todayFocus(
          [session(1, today, status: status), session(2, today, hour: 16)],
          today: today,
          now: rome(11),
        );
        expect(
          ids(focus.sessions),
          [sessionId(2), sessionId(1)],
          reason: status.name,
        );
      }
    });

    test('las canceladas no cuentan, ni hoy ni como próxima', () {
      final focus = todayFocus(
        [
          session(1, today, status: SessionStatus.cancelled),
          session(2, today.addDays(1), status: SessionStatus.cancelled),
          session(3, today.addDays(2)),
        ],
        today: today,
        now: rome(8),
      );
      expect(focus.isToday, isFalse);
      expect(ids(focus.sessions), [sessionId(3)]);
    });

    test('una sesión retenida por un presupuesto (held) cuenta como viva', () {
      final focus = todayFocus(
        [session(1, today.addDays(1), status: SessionStatus.held)],
        today: today,
        now: rome(8),
      );
      expect(ids(focus.sessions), [sessionId(1)]);
    });

    test('las de días pasados no cuentan aunque sigan confirmadas', () {
      final focus = todayFocus(
        [session(1, today.addDays(-1)), session(2, today.addDays(3))],
        today: today,
        now: rome(8),
      );
      expect(focus.isToday, isFalse);
      expect(ids(focus.sessions), [sessionId(2)]);
    });

    test('sin ninguna viva desde hoy, vacía', () {
      final focus = todayFocus(
        [
          session(1, today.addDays(-1)),
          session(2, today.addDays(4), status: SessionStatus.cancelled),
        ],
        today: today,
        now: rome(8),
      );
      expect(focus.sessions, isEmpty);
      expect(focus.main, isNull);
      expect(focus, TodayFocus.empty);
    });

    test('a las 23:30 UTC de invierno ya es el día siguiente en Roma', () {
      final now = DateTime.utc(2026, 11, 17, 23, 30);
      final tomorrow = romeToday(now);
      expect(tomorrow, CalendarDate(2026, 11, 18));
      final focus = todayFocus(
        [session(1, today, hour: 20), session(2, tomorrow)],
        today: tomorrow,
        now: now,
      );
      expect(focus.isToday, isTrue, reason: 'la del 18 ya es de hoy');
      expect(ids(focus.sessions), [sessionId(2)]);
    });

    test('dos resultados con las mismas sesiones son iguales', () {
      final sessions = [session(1, today), session(2, today, hour: 16)];
      expect(
        todayFocus(sessions, today: today, now: rome(8)),
        todayFocus(sessions, today: today, now: rome(9)),
      );
      expect(
        todayFocus(sessions, today: today, now: rome(8)),
        isNot(todayFocus(sessions, today: today, now: rome(14))),
      );
    });
  });

  group('cuándo terminó una sesión (hora de Roma)', () {
    test('cuando pasa la hora en que termina la cocina', () {
      // 10:00 + 180 minutos: hasta las 13:00 en Roma.
      final s = session(1, today);
      expect(sessionFinished(s, rome(12, 59)), isFalse);
      expect(sessionFinished(s, rome(13)), isTrue);
      // Un día antes, no; un día después, sí.
      expect(sessionFinished(s, rome(14).subtract(const Duration(days: 1))), isFalse);
      expect(sessionFinished(s, rome(9).add(const Duration(days: 1))), isTrue);
    });

    test('en verano, con UTC+2', () {
      final s = session(1, CalendarDate(2026, 10, 19));
      expect(sessionFinished(s, DateTime.utc(2026, 10, 19, 10, 59)), isFalse);
      expect(sessionFinished(s, DateTime.utc(2026, 10, 19, 11)), isTrue);
    });

    test('cocinada o cobrada, siempre', () {
      expect(
        sessionFinished(session(1, today, status: SessionStatus.cooked), rome(8)),
        isTrue,
      );
      expect(
        sessionFinished(session(1, today, status: SessionStatus.paid), rome(8)),
        isTrue,
      );
    });
  });

  group('reservas que terminan', () {
    /// Las semanas de la reserva [requestId], una por fecha.
    List<CookingSession> booking(
      String requestId,
      List<CalendarDate> dates, {
      int firstN = 1,
      Map<int, SessionStatus> statuses = const {},
      RequestType type = RequestType.week,
    }) => [
      for (final (i, date) in dates.indexed)
        session(
          firstN + i,
          date,
          requestId: requestId,
          status: statuses[i] ?? SessionStatus.confirmed,
          type: type,
        ),
    ];

    test('la última semana viva cae entre hoy y dentro de 6 días', () {
      final ending = endingBookings([
        // Miércoles 28/10 a 18/11: termina mañana.
        ...booking('a', [
          CalendarDate(2026, 10, 28),
          CalendarDate(2026, 11, 4),
          CalendarDate(2026, 11, 11),
          CalendarDate(2026, 11, 18),
        ]),
        // Sigue hasta el 2/12: no termina esta semana.
        ...booking('b', [
          CalendarDate(2026, 11, 18),
          CalendarDate(2026, 11, 25),
          CalendarDate(2026, 12, 2),
        ], firstN: 10),
      ], today: today);
      expect(ids(ending), [sessionId(4)]);
      expect(ending.single.requestId, 'a');
    });

    test('los bordes: hoy y dentro de 6 días sí; dentro de 7 o ayer, no', () {
      final ending = endingBookings([
        ...booking('ayer', [today.addDays(-1)], firstN: 1),
        ...booking('hoy', [today], firstN: 2),
        ...booking('seis', [today.addDays(6)], firstN: 3),
        ...booking('siete', [today.addDays(7)], firstN: 4),
      ], today: today);
      expect([for (final s in ending) s.requestId], ['hoy', 'seis']);
    });

    test('una semana cancelada al final no cuenta; una viva después, sí', () {
      final ending = endingBookings([
        // La última viva es el 18/11: la del 25/11 está cancelada.
        ...booking(
          'c',
          [
            CalendarDate(2026, 11, 11),
            CalendarDate(2026, 11, 18),
            CalendarDate(2026, 11, 25),
          ],
          statuses: {2: SessionStatus.cancelled},
        ),
        // La del 18/11 está cancelada y la del 25/11 sigue: no termina.
        ...booking(
          'd',
          [CalendarDate(2026, 11, 18), CalendarDate(2026, 11, 25)],
          firstN: 10,
          statuses: {0: SessionStatus.cancelled},
        ),
      ], today: today);
      expect(ids(ending), [sessionId(2)]);
    });

    test('una semana ya cocinada que es la última también termina', () {
      final ending = endingBookings(
        booking('e', [today], statuses: {0: SessionStatus.cooked}),
        today: today,
      );
      expect(ids(ending), [sessionId(1)]);
    });

    test('sin pedido o de una sesión extra, no es una reserva que termina', () {
      final ending = endingBookings([
        session(1, today.addDays(1), requestId: null),
        ...booking('extra', [today.addDays(2)], firstN: 2, type: RequestType.extra),
      ], today: today);
      expect(ending, isEmpty);
    });

    test('un presupuesto enviado (sesión held, pedido quoted) todavía no es una reserva', () {
      final ending = endingBookings([
        session(
          1,
          today.addDays(2),
          requestId: 'presupuesto',
          status: SessionStatus.held,
          requestStatus: RequestStatus.quoted,
        ),
      ], today: today);
      expect(ending, isEmpty);
    });

    test('sin el pedido embebido no se sabe si es una reserva semanal: no cuenta', () {
      final ending = endingBookings([
        session(1, today.addDays(2), requestId: 'sin-embeber').copyWith(
          request: null,
        ),
      ], today: today);
      expect(ending, isEmpty);
    });

    test('una reserva de una sola semana también termina', () {
      final ending = endingBookings([
        session(1, today.addDays(2), requestId: 'una', weeks: 1),
      ], today: today);
      expect(ids(ending), [sessionId(1)]);
    });

    test('una por reserva, con su última sesión, por fecha', () {
      final ending = endingBookings([
        // Lunes 23/11 y miércoles 18/11 de la misma reserva: la última es el 23.
        ...booking('f', [CalendarDate(2026, 11, 23), CalendarDate(2026, 11, 18)]),
        ...booking('g', [CalendarDate(2026, 11, 19)], firstN: 5),
      ], today: today);
      expect(ids(ending), [sessionId(5), sessionId(1)]);
    });
  });

  group('la tira de 7 días', () {
    test('hoy y los 6 siguientes, con las sesiones vivas de cada uno', () {
      final strip = todayStrip(
        today: today,
        sessionsByDate: sessionsByDate([
          session(1, today),
          session(2, today, hour: 16),
          session(3, today.addDays(2)),
          session(4, today.addDays(3), status: SessionStatus.cancelled),
          session(5, today.addDays(7)),
        ]),
        availability: null,
      );
      expect([for (final day in strip) day.date], [
        for (var i = 0; i < 7; i++) today.addDays(i),
      ]);
      expect([for (final day in strip) day.sessionCount], [2, 0, 1, 0, 0, 0, 0]);
    });

    test('bloqueado, sin horario, abierto y feriado, como en la agenda', () {
      // Lunes 7/12/2026: el martes 8 es la Immacolata; el miércoles 9, bloqueado.
      final monday = CalendarDate(2026, 12, 7);
      final strip = todayStrip(
        today: monday,
        sessionsByDate: const {},
        availability: AvailabilitySnapshot(
          rules: weekdayRules(),
          blocked: {
            CalendarDate(2026, 12, 9): BlockedDay(
              id: 'block-1',
              date: CalendarDate(2026, 12, 9),
            ),
          },
        ),
      );
      expect([for (final day in strip) day.status], [
        DayStatus.open,
        DayStatus.open,
        DayStatus.blocked,
        DayStatus.open,
        DayStatus.open,
        DayStatus.closed,
        DayStatus.closed,
      ]);
      expect(strip[1].holiday, ItalianHoliday.immaculate);
      expect(strip[2].isBlocked, isTrue);
      expect([for (final day in strip) day.holiday].nonNulls, [
        ItalianHoliday.immaculate,
      ]);
    });

    test('sin la disponibilidad (cargando o con error), sin estado', () {
      final strip = todayStrip(
        today: CalendarDate(2026, 12, 7),
        sessionsByDate: const {},
        availability: null,
      );
      expect([for (final day in strip) day.status].nonNulls, isEmpty);
      expect(strip.any((day) => day.isBlocked), isFalse);
      expect(strip[1].holiday, ItalianHoliday.immaculate);
    });
  });
}

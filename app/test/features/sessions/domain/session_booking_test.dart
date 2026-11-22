// Las semanas de una reserva («Semana k de N» sin contar las canceladas, las
// siguientes, el final de la reserva, qué ofrecer si alguna que se quiso
// cancelar ya está cobrada), la última sesión viva de una reserva semanal
// (donde va «Rinnova»), la próxima sesión viva de la misma ficha, las
// sesiones de cada día de la agenda y desde qué día las lee (también 7 días
// antes de hoy). El enlace de «Cómo llegar», en session_links_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

import '../../../support/session_fixtures.dart';

void main() {
  group('«Semana k de N»', () {
    test('la posición entre las semanas de la reserva, por fecha', () {
      final booking = buildBooking();
      expect(
        [for (final s in booking) bookingPosition(s, booking)],
        [
          (week: 1, weeks: 4),
          (week: 2, weeks: 4),
          (week: 3, weeks: 4),
          (week: 4, weeks: 4),
        ],
      );
    });

    test('sin contar las canceladas: la cancelada no tiene número', () {
      final booking = buildBooking(statuses: {2: SessionStatus.cancelled});
      expect(bookingPosition(booking[0], booking), (week: 1, weeks: 3));
      expect(bookingPosition(booking[1], booking), isNull);
      expect(bookingPosition(booking[2], booking), (week: 2, weeks: 3));
      expect(bookingPosition(booking[3], booking), (week: 3, weeks: 3));
    });

    test(
      'las cocinadas y cobradas cuentan (siguen siendo semanas de la reserva)',
      () {
        final booking = buildBooking(
          statuses: {1: SessionStatus.paid, 2: SessionStatus.cooked},
        );
        expect(bookingPosition(booking[2], booking), (week: 3, weeks: 4));
      },
    );

    test(
      'un orden que no es el de la lista, y una semana movida antes que otra',
      () {
        final booking = buildBooking();
        final moved = booking[3].copyWith(date: CalendarDate(2026, 11, 20));
        final shuffled = [booking[2], booking[0], moved, booking[1]];
        expect(bookingPosition(moved, shuffled), (week: 1, weeks: 4));
        expect(bookingPosition(booking[0], shuffled), (week: 2, weeks: 4));
      },
    );

    test('una sola semana, una sesión sin reserva o sesiones de otro pedido: sin número', () {
      final single = buildBooking(weeks: 1);
      expect(bookingPosition(single.single, single), isNull);

      final alone = buildSession(requestId: null);
      expect(bookingPosition(alone, [alone]), isNull);

      final booking = buildBooking(weeks: 2);
      final other = buildSession(n: 9, requestId: 'otro-pedido');
      expect(bookingPosition(booking[0], [...booking, other]), (
        week: 1,
        weeks: 2,
      ));
    });

    test('si la lista no la trae, la sesión cuenta igual', () {
      final booking = buildBooking(weeks: 3);
      expect(bookingPosition(booking[2], booking.take(2)), (week: 3, weeks: 3));
    });
  });

  group('las siguientes', () {
    test('las semanas después, que todavía se pueden cancelar', () {
      final booking = buildBooking(
        weeks: 5,
        statuses: {4: SessionStatus.cancelled},
      );
      expect(followingSessions(booking[1], booking).map((s) => s.id), [
        sessionId(3),
        sessionId(5),
      ]);
      expect(followingSessions(booking[4], booking), isEmpty);
    });

    test('una siguiente ya cocinada no se ofrece (no se podría cancelar)', () {
      final booking = buildBooking(statuses: {3: SessionStatus.cooked});
      expect(followingSessions(booking[0], booking).map((s) => s.id), [
        sessionId(2),
        sessionId(4),
      ]);
    });
  });

  group('el final de la reserva', () {
    test('la semana después de la última, el mismo día de la semana', () {
      final booking = buildBooking();
      // Las semanas: 25/11, 2/12, 9/12 y 16/12 (miércoles).
      expect(endOfBookingDate(booking[1], booking), CalendarDate(2026, 12, 23));
    });

    test('sin contar las canceladas ni la que se mueve', () {
      final booking = buildBooking(statuses: {4: SessionStatus.cancelled});
      expect(endOfBookingDate(booking[0], booking), CalendarDate(2026, 12, 16));
    });

    test('si ya es la última, o la única, no hay final al que pasarla', () {
      final booking = buildBooking();
      expect(endOfBookingDate(booking[3], booking), isNull);
      final single = buildBooking(weeks: 1);
      expect(endOfBookingDate(single.single, single), isNull);
      final alone = buildSession(requestId: null);
      expect(endOfBookingDate(alone, [alone]), isNull);
    });
  });

  group('si una semana que se quiso cancelar ya está cobrada (409 hasPayments)', () {
    // Las semanas: 25/11, 2/12, 9/12 y 16/12. Se cancela desde la 2.
    final booking = buildBooking();
    final current = booking[1];
    List<String> ids(List<CookingSession> sessions) => [
      for (final session in sessions) session.id,
    ];

    test('solo la de la ficha, cobrada: pasarla al final (decisión 5 del plan)', () {
      final plan = hasPaymentsPlan(
        current: current,
        booking: booking,
        requested: [current],
        paidIds: [current.id],
      );
      expect(ids(plan.paid), [sessionId(2)]);
      expect(plan.unpaid, isEmpty);
      expect(plan.moveToEnd, CalendarDate(2026, 12, 23));
    });

    test('con «también las siguientes» no ofrece pasarla al final: el final cuenta las que se querían cancelar', () {
      final plan = hasPaymentsPlan(
        current: current,
        booking: booking,
        requested: [current, booking[2], booking[3]],
        paidIds: [current.id],
      );
      expect(ids(plan.paid), [sessionId(2)]);
      expect(ids(plan.unpaid), [sessionId(3), sessionId(4)]);
      expect(plan.moveToEnd, isNull);
    });

    test('si la cobrada es una de las siguientes, esa es la cobrada y las demás se pueden cancelar', () {
      final plan = hasPaymentsPlan(
        current: current,
        booking: booking,
        requested: [current, booking[2], booking[3]],
        paidIds: [sessionId(3)],
      );
      expect(ids(plan.paid), [sessionId(3)]);
      expect(ids(plan.unpaid), [sessionId(2), sessionId(4)]);
      expect(plan.moveToEnd, isNull);
    });

    test('varias cobradas, por fecha', () {
      final plan = hasPaymentsPlan(
        current: current,
        booking: booking,
        requested: [current, booking[2], booking[3]],
        paidIds: [sessionId(3), sessionId(2)],
      );
      expect(ids(plan.paid), [sessionId(2), sessionId(3)]);
      expect(ids(plan.unpaid), [sessionId(4)]);
    });

    test('la última, o una que ya no se mueve, no se puede pasar al final', () {
      final last = hasPaymentsPlan(
        current: booking[3],
        booking: booking,
        requested: [booking[3]],
        paidIds: [sessionId(4)],
      );
      expect(last.moveToEnd, isNull);
      expect(last.unpaid, isEmpty);

      final shopped = booking[1].copyWith(status: SessionStatus.shoppingDone);
      final notMovable = hasPaymentsPlan(
        current: shopped,
        booking: [booking[0], shopped, booking[2], booking[3]],
        requested: [shopped],
        paidIds: [shopped.id],
      );
      expect(notMovable.moveToEnd, isNull);
    });

    test('si el servidor no dice cuáles (o ninguna de las pedidas), se toman todas como cobradas: nunca se ofrece repetir lo mismo', () {
      for (final paidIds in [<String>[], <String>['otra']]) {
        final several = hasPaymentsPlan(
          current: current,
          booking: booking,
          requested: [current, booking[2]],
          paidIds: paidIds,
        );
        expect(ids(several.paid), [sessionId(2), sessionId(3)]);
        expect(several.unpaid, isEmpty);

        final single = hasPaymentsPlan(
          current: current,
          booking: booking,
          requested: [current],
          paidIds: paidIds,
        );
        expect(single.moveToEnd, CalendarDate(2026, 12, 23));
      }
    });
  });

  test('las sesiones de cada día, por llegada y sin las canceladas', () {
    final day = CalendarDate(2026, 11, 25);
    final late = buildSession(
      n: 1,
      date: day,
      start: const ClockTime.hm(13, 0),
    );
    final early = buildSession(
      n: 2,
      date: day,
      start: const ClockTime.hm(9, 30),
    );
    final cancelled = buildSession(
      n: 3,
      date: day,
      status: SessionStatus.cancelled,
    );
    final other = buildSession(n: 4, date: day.addDays(1));
    final byDate = sessionsByDate([late, cancelled, other, early]);
    expect(byDate.keys, unorderedEquals([day, day.addDays(1)]));
    expect(byDate[day]!.map((s) => s.id), [sessionId(2), sessionId(1)]);
  });

  group('desde qué día lee la agenda', () {
    final today = CalendarDate(2026, 11, 16);

    test('el lunes de la primera semana del mes de hoy', () {
      expect(
        sessionsWindowFrom(today: today, selected: today),
        CalendarDate(2026, 10, 26),
      );
      // Más adelante no cambia: hacia adelante no hay tope.
      expect(
        sessionsWindowFrom(today: today, selected: CalendarDate(2027, 1, 13)),
        CalendarDate(2026, 10, 26),
      );
    });

    test(
      'si se elige un mes anterior, desde el lunes de su primera semana',
      () {
        expect(
          sessionsWindowFrom(today: today, selected: CalendarDate(2026, 9, 10)),
          CalendarDate(2026, 8, 31),
        );
      },
    );

    test('desde 7 días antes de hoy si es antes: Hoy muestra las reservas que terminaron hace hasta 7 días', () {
      // Jueves 3/12/2026: el lunes de la primera semana del mes es el 30/11,
      // y hace 7 días era el 26/11.
      final december = CalendarDate(2026, 12, 3);
      expect(
        sessionsWindowFrom(today: december, selected: december),
        CalendarDate(2026, 11, 26),
      );
      expect(endingBookingNoticeDays, 7);
      // El 17/11 el lunes de la primera semana del mes (26/10) ya es antes.
      final november = CalendarDate(2026, 11, 17);
      expect(
        sessionsWindowFrom(today: november, selected: november),
        CalendarDate(2026, 10, 26),
      );
      // Un mes elegido anterior sigue mandando.
      expect(
        sessionsWindowFrom(today: december, selected: CalendarDate(2026, 10, 5)),
        CalendarDate(2026, 9, 28),
      );
    });
  });

  group('la última sesión viva de una reserva semanal (donde va «Rinnova»)', () {
    test('la última viva, sí; una que no es la última, no', () {
      final booking = buildBooking();
      expect(isLastLiveOfWeeklyBooking(booking[3], booking), isTrue);
      expect(isLastLiveOfWeeklyBooking(booking[2], booking), isFalse);
    });

    test('con la última cancelada, la anterior pasa a ser la última; la cancelada, no', () {
      final booking = buildBooking(statuses: {4: SessionStatus.cancelled});
      expect(isLastLiveOfWeeklyBooking(booking[3], booking), isFalse);
      expect(isLastLiveOfWeeklyBooking(booking[2], booking), isTrue);
    });

    test('la última ya cocinada (o cobrada), sí', () {
      for (final status in [SessionStatus.cooked, SessionStatus.paid]) {
        final booking = buildBooking(statuses: {4: status});
        expect(
          isLastLiveOfWeeklyBooking(booking[3], booking),
          isTrue,
          reason: status.name,
        );
      }
    });

    test('una sesión extra, sin pedido o de un presupuesto (held, pedido quoted), no', () {
      final extra = buildSession(type: RequestType.extra, weeks: 1);
      expect(isLastLiveOfWeeklyBooking(extra, [extra]), isFalse);
      final alone = buildSession(requestId: null);
      expect(isLastLiveOfWeeklyBooking(alone, [alone]), isFalse);
      final quote = buildSession(
        status: SessionStatus.held,
        requestStatus: RequestStatus.quoted,
      );
      expect(isLastLiveOfWeeklyBooking(quote, [quote]), isFalse);
    });
  });

  group('la próxima sesión viva de la misma ficha', () {
    // La reserva de prueba: 25/11, 2/12, 9/12 y 16/12; la última es el 16/12.
    final booking = buildBooking();
    final last = booking.last;

    test('otra reserva de la misma ficha, después: sí, y devuelve la primera', () {
      final renewal = buildBooking(
        first: CalendarDate(2026, 12, 23),
        firstN: 10,
        requestId: 'renovacion',
      );
      final sessions = [...booking, ...renewal.reversed];
      expect(nextLiveSessionOfClient(last, sessions)?.id, sessionId(10));
      expect(hasLaterLiveSession(last, sessions), isTrue);
    });

    test('el mismo día pero más tarde también es posterior; antes, no', () {
      final later = buildSession(
        n: 20,
        requestId: 'suelta',
        date: last.date,
        start: const ClockTime.hm(16, 0),
      );
      final earlier = buildSession(
        n: 21,
        requestId: 'antes',
        date: CalendarDate(2026, 12, 1),
      );
      expect(nextLiveSessionOfClient(last, [...booking, earlier]), isNull);
      expect(nextLiveSessionOfClient(last, [...booking, later])?.id, sessionId(20));
    });

    test('una posterior cancelada no cuenta, ni la de otra ficha', () {
      final cancelled = buildSession(
        n: 30,
        requestId: 'cancelada',
        date: CalendarDate(2026, 12, 23),
        status: SessionStatus.cancelled,
      );
      final otherClient = buildSession(
        n: 31,
        requestId: 'otra-ficha',
        clientId: 'otra-ficha',
        date: CalendarDate(2026, 12, 30),
      );
      final sessions = [...booking, cancelled, otherClient];
      expect(nextLiveSessionOfClient(last, sessions), isNull);
      expect(hasLaterLiveSession(last, sessions), isFalse);
    });
  });
}

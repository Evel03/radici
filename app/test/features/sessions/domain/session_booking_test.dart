// Las semanas de una reserva («Semana k de N» sin contar las canceladas, las
// siguientes, el final de la reserva, qué ofrecer si alguna que se quiso
// cancelar ya está cobrada), las sesiones de cada día de la agenda, desde qué
// día las lee y el enlace de «Cómo llegar».
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';
import 'package:radici/features/sessions/domain/session_links.dart';

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
  });

  group('«Cómo llegar»', () {
    const address = 'Via Gombito 12, 24129 Bergamo';

    test('en el iPhone, Apple Maps con el camino hasta la dirección', () {
      expect(
        directionsUri(address: address, apple: true).toString(),
        'https://maps.apple.com/?daddr=Via%20Gombito%2012%2C%2024129%20Bergamo',
      );
    });

    test('en Android y en el resto, Google Maps', () {
      expect(
        directionsUri(address: address, apple: false).toString(),
        'https://www.google.com/maps/dir/?api=1&destination=Via%20Gombito%2012%2C%2024129%20Bergamo',
      );
    });

    test('sin dirección, nada que abrir', () {
      expect(directionsUri(address: null, apple: true), isNull);
      expect(directionsUri(address: '   ', apple: false), isNull);
    });

    test('un & o un # en la dirección no cortan el enlace', () {
      final uri = directionsUri(address: 'Via A & B #3', apple: true)!;
      expect(uri.queryParameters['daddr'], 'Via A & B #3');
    });
  });
}

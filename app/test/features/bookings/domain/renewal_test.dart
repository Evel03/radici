// «Rinnova» (decisión 2): de las sesiones de una reserva semanal (también
// las canceladas) sale lo que propone la hoja. La primera fecha es la última
// sesión viva + 7 días; se copian la llegada, los minutos (tal cual, también
// más de 300), las porciones y la compra de esa sesión; las semanas y el
// precio cuentan todas las sesiones, también las canceladas; el hogar
// (ajustado a los límites del contrato) y el idioma son los del pedido. Con
// la última semana movida, el día y la hora salen de ella y se avisa; con
// otro teléfono en el pedido, también. Al cambiar las semanas, el precio
// sigue a las tarifas de la estimación solo si el total era el de esas
// tarifas. Una sesión extra, sin pedido o sin sesiones vivas no se renueva.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/renewal.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  /// Miércoles 25/11, 2/12, 9/12 y 16/12 a las 10:00, 180 min, 4 × 140 €.
  List<CookingSession> normal({Map<int, SessionStatus> statuses = const {}}) =>
      buildBooking(statuses: statuses);

  group('la tabla de «Rinnova»', () {
    test('normal: 4 semanas desde el 23/12, a las 10:00, 180 min y 560 €', () {
      final plan = renewalPlan(normal())!;
      expect(plan.last.id, sessionId(4));
      expect(plan.weeks, 4);
      expect(plan.firstDate, CalendarDate(2026, 12, 23));
      expect(plan.dates, [
        CalendarDate(2026, 12, 23),
        CalendarDate(2026, 12, 30),
        CalendarDate(2027, 1, 6),
        CalendarDate(2027, 1, 13),
      ]);
      expect(plan.start, const ClockTime.hm(10, 0));
      expect(plan.cookMinutes, 180);
      expect(plan.serviceTotalCents, 56000);
      expect(plan.lastMoved, isFalse);
      expect(plan.otherRequestPhone, isNull);
    });

    test('una del medio cancelada: la última viva sigue siendo el 16/12; 4 semanas y 560 €', () {
      final plan = renewalPlan(normal(statuses: {3: SessionStatus.cancelled}))!;
      expect(plan.last.id, sessionId(4));
      expect(plan.firstDate, CalendarDate(2026, 12, 23));
      expect(plan.weeks, 4);
      expect(plan.serviceTotalCents, 56000);
    });

    test('la última cancelada: la última viva es el 9/12 y empieza el 16/12', () {
      final plan = renewalPlan(normal(statuses: {4: SessionStatus.cancelled}))!;
      expect(plan.last.id, sessionId(3));
      expect(plan.dates, [
        CalendarDate(2026, 12, 16),
        CalendarDate(2026, 12, 23),
        CalendarDate(2026, 12, 30),
        CalendarDate(2027, 1, 6),
      ]);
      expect(plan.weeks, 4);
      expect(plan.serviceTotalCents, 56000);
    });

    test('la última movida al viernes 18/12 a las 11:00: el día y la hora salen de ella, y se avisa', () {
      final booking = normal();
      booking[3] = booking[3].copyWith(
        date: CalendarDate(2026, 12, 18),
        start: const ClockTime.hm(11, 0),
      );
      final plan = renewalPlan(booking)!;
      expect(plan.dates, [
        CalendarDate(2026, 12, 25),
        CalendarDate(2027, 1, 1),
        CalendarDate(2027, 1, 8),
        CalendarDate(2027, 1, 15),
      ]);
      expect(plan.start, const ClockTime.hm(11, 0));
      expect(plan.lastMoved, isTrue);
    });

    test('la última movida solo de hora también se avisa', () {
      final booking = normal();
      booking[3] = booking[3].copyWith(start: const ClockTime.hm(11, 30));
      final plan = renewalPlan(booking)!;
      expect(plan.firstDate, CalendarDate(2026, 12, 23));
      expect(plan.start, const ClockTime.hm(11, 30));
      expect(plan.lastMoved, isTrue);
    });

    test('reparto desparejo: 166,67 + 166,67 + 166,66 dan 3 semanas y 500 €', () {
      final booking = buildBooking(weeks: 3);
      final shares = [16667, 16667, 16666];
      final split = [
        for (final (i, session) in booking.indexed)
          session.copyWith(serviceCents: shares[i]),
      ];
      final plan = renewalPlan(split)!;
      expect(plan.weeks, 3);
      expect(plan.serviceTotalCents, 50000);
    });

    test('la última el martes 10/11: empieza el 17/11 a las 10:00 (desde Hoy, el día +7)', () {
      final plan = renewalPlan(buildBooking(first: CalendarDate(2026, 10, 20)))!;
      expect(plan.last.date, CalendarDate(2026, 11, 10));
      expect(plan.firstDate, CalendarDate(2026, 11, 17));
      expect(plan.start, const ClockTime.hm(10, 0));
    });

    test('la última hace más de 7 días (3/11): empieza el 10/11 igual; la hoja avisa las fechas pasadas', () {
      final plan = renewalPlan(buildBooking(first: CalendarDate(2026, 10, 13)))!;
      expect(plan.last.date, CalendarDate(2026, 11, 3));
      expect(plan.firstDate, CalendarDate(2026, 11, 10));
    });

    test('no se renueva: una sesión extra, sin pedido, sin sesiones vivas o un presupuesto', () {
      expect(
        renewalPlan([buildSession(type: RequestType.extra, weeks: 1)]),
        isNull,
      );
      expect(renewalPlan([buildSession(requestId: null)]), isNull);
      expect(
        renewalPlan(
          normal(
            statuses: {
              for (var week = 1; week <= 4; week++)
                week: SessionStatus.cancelled,
            },
          ),
        ),
        isNull,
      );
      expect(
        renewalPlan([
          buildSession(
            status: SessionStatus.held,
            requestStatus: RequestStatus.quoted,
          ),
        ]),
        isNull,
      );
      expect(renewalPlan(const []), isNull);
    });
  });

  group('lo que se copia', () {
    test('la ficha, el idioma y la estimación del pedido; las porciones y la compra de la última viva', () {
      final booking = buildBooking(
        locale: ClientLocale.es,
        estimate: fourWeeksEstimate,
        portions: 15,
      );
      booking[3] = booking[3].copyWith(groceriesEstCents: 5100);
      final plan = renewalPlan(booking)!;
      expect(plan.clientId, testClientId);
      expect(plan.locale, ClientLocale.es);
      expect(plan.estimate, fourWeeksEstimate);
      expect(plan.portions, 15);
      expect(plan.groceriesEstCents, 5100);
    });

    test('los minutos tal cual, también más de 300', () {
      final booking = [
        for (final session in normal()) session.copyWith(cookMinutes: 360),
      ];
      expect(renewalPlan(booking)!.cookMinutes, 360);
    });

    test('el hogar del pedido, ajustado a los límites del contrato', () {
      final booking = [
        for (final session in normal())
          session.copyWith(
            request: session.request!.copyWith(
              adults: 40,
              kids: 0,
              days: 9,
              meals: const [Meal.dinner, Meal.lunch],
            ),
          ),
      ];
      expect(
        renewalPlan(booking)!.household,
        const BookingHousehold(
          adults: 30,
          kids: 0,
          days: 7,
          meals: [Meal.lunch, Meal.dinner],
        ),
      );
    });

    test('si al pedido le falta el hogar: adultos y niños de la ficha, 5 días y cena', () {
      final booking = [
        for (final session in normal())
          session.copyWith(
            request: session.request!.copyWith(days: null, meals: const []),
            client: session.client.copyWith(adults: 3, kids: 1),
          ),
      ];
      expect(
        renewalPlan(booking)!.household,
        const BookingHousehold(adults: 3, kids: 1, days: 5, meals: [Meal.dinner]),
      );
    });

    test('toString sin datos de la clienta', () {
      final text = renewalPlan(normal())!.toString();
      expect(text, isNot(contains('Giulia')));
      expect(text, isNot(contains('333')));
      expect(text, isNot(contains('Gombito')));
    });
  });

  group('otro teléfono en el pedido renovado', () {
    List<CookingSession> withRequestPhone(String? phone) => [
      for (final session in normal())
        session.copyWith(
          request: session.request!.copyWith(
            client: session.request!.client.copyWith(contactPhone: phone),
          ),
        ),
    ];

    test('si el E.164 no es el de la ficha, el del pedido como lo escribió la clienta', () {
      expect(
        renewalPlan(withRequestPhone('+34 612 345 678'))!.otherRequestPhone,
        '+34 612 345 678',
      );
    });

    test('el mismo número escrito de otra forma, o sin contacto propio: null', () {
      expect(
        renewalPlan(withRequestPhone('333 123 4567'))!.otherRequestPhone,
        isNull,
      );
      // Sin contact, el pedido muestra el teléfono de la ficha.
      expect(renewalPlan(normal())!.otherRequestPhone, isNull);
      expect(renewalPlan(withRequestPhone(null))!.otherRequestPhone, isNull);
    });
  });

  group('el precio al cambiar las semanas', () {
    test('las mismas semanas: el total original', () {
      expect(
        renewalPriceFor(originalTotal: 56000, originalWeeks: 4, weeks: 4),
        56000,
      );
      expect(
        renewalPriceFor(
          originalTotal: 50000,
          originalWeeks: 4,
          weeks: 4,
          estimate: fourWeeksEstimate,
        ),
        50000,
      );
    });

    test('con la estimación de la web (150 € por semana, 140 € desde 4) y 560 € en 4: 300 € en 2 y 450 € en 3', () {
      int? price(int weeks) => renewalPriceFor(
        originalTotal: 56000,
        originalWeeks: 4,
        weeks: weeks,
        estimate: fourWeeksEstimate,
      );
      expect(price(2), 30000);
      expect(price(3), 45000);
      expect(price(5), 70000);
    });

    test('sin estimación con tarifas, o con un total acordado distinto: vacío (lo escribe Evelyn)', () {
      expect(
        renewalPriceFor(originalTotal: 56000, originalWeeks: 4, weeks: 2),
        isNull,
      );
      expect(
        renewalPriceFor(
          originalTotal: 56000,
          originalWeeks: 4,
          weeks: 2,
          estimate: legacyEstimate,
        ),
        isNull,
      );
      expect(
        renewalPriceFor(
          originalTotal: 50000,
          originalWeeks: 4,
          weeks: 2,
          estimate: fourWeeksEstimate,
        ),
        isNull,
      );
    });
  });
}

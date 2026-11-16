// Reglas de la hoja «Confirmar reserva»: semanas y fechas cada 7 días, lo que
// impide mandar una fecha, los minutos con tope de 300, el precio que se
// propone y las horas de llegada.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/request_fixtures.dart';

void main() {
  final today = CalendarDate(2026, 10, 19); // lunes, como testNow
  final monday = CalendarDate(2026, 11, 23);

  group('semanas y fechas', () {
    test(
      'la reserva empieza con las semanas del pedido y la fecha preferida',
      () {
        final request = buildRequest(weeks: 4, preferredDate: monday);
        expect(initialBookingWeeks(request), 4);
        expect(initialBookingDate(request, today: today), monday);
        // Sin fecha preferida: mañana.
        expect(
          initialBookingDate(buildRequest(noDate: true), today: today),
          today.addDays(1),
        );
        // Una sesión extra es de una sola fecha.
        expect(
          initialBookingWeeks(buildRequest(type: RequestType.extra, weeks: 3)),
          1,
        );
        expect(maxWeeksFor(RequestType.week), 8);
        expect(maxWeeksFor(RequestType.extra), 1);
      },
    );

    test('cada 7 días desde la primera', () {
      expect(weeklyDates(monday, 4), [
        CalendarDate(2026, 11, 23),
        CalendarDate(2026, 11, 30),
        CalendarDate(2026, 12, 7),
        CalendarDate(2026, 12, 14),
      ]);
      expect(weeklyDates(monday, 1), [monday]);
    });

    test('sumar semanas agrega al final, 7 días después de la última; restar saca las últimas', () {
      final edited = [monday, monday.addDays(9)]; // la segunda, un miércoles
      expect(resizeBookingWeeks(edited, 4), [
        monday,
        monday.addDays(9),
        monday.addDays(16),
        monday.addDays(23),
      ]);
      expect(
        resizeBookingWeeks(weeklyDates(monday, 4), 2),
        weeklyDates(monday, 2),
      );
      expect(
        resizeBookingWeeks(weeklyDates(monday, 3), 3),
        weeklyDates(monday, 3),
      );
      expect(() => resizeBookingWeeks([monday], 0), throwsRangeError);
      expect(() => resizeBookingWeeks([monday], 9), throwsRangeError);
    });

    test('cambiar la primera fecha mueve toda la reserva; otra, solo la suya', () {
      final dates = [
        monday,
        monday.addDays(7),
        monday.addDays(16),
        monday.addDays(21),
      ];
      // La primera, una semana después: todas se corren 7 días (con la tercera,
      // que era un miércoles, igual).
      expect(changeBookingDate(dates, 0, monday.addDays(7)), [
        monday.addDays(7),
        monday.addDays(14),
        monday.addDays(23),
        monday.addDays(28),
      ]);
      // La segunda pasa al jueves: las demás quedan.
      expect(changeBookingDate(dates, 1, monday.addDays(10)), [
        monday,
        monday.addDays(10),
        monday.addDays(16),
        monday.addDays(21),
      ]);
      expect(() => changeBookingDate(dates, 4, monday), throwsRangeError);
    });

    test('lo que impide mandar una fecha: la misma semana, el orden y más de un año', () {
      expect(bookingDateIssues(weeklyDates(monday, 4), today: today), [
        null,
        null,
        null,
        null,
      ]);
      // El domingo de la misma semana que el lunes anterior.
      expect(bookingDateIssues([monday, monday.addDays(6)], today: today), [
        null,
        BookingDateIssue.sameWeek,
      ]);
      // Una semana antes de la anterior.
      expect(
        bookingDateIssues([
          monday,
          monday.addDays(7),
          monday.addDays(-7),
        ], today: today),
        [null, null, BookingDateIssue.order],
      );
      // Pasadas valen (Fase 0); a más de 365 días, no.
      expect(bookingDateIssues([today.addDays(-30)], today: today), [null]);
      expect(
        bookingDateIssues([
          today.addDays(-366),
          today.addDays(366),
        ], today: today),
        [BookingDateIssue.outOfRange, BookingDateIssue.outOfRange],
      );
      expect(bookingDateIssues([today.addDays(365)], today: today), [null]);
    });
  });

  group('minutos de cocina', () {
    test('los de la estimación, con tope de 300', () {
      expect(suggestedCookMinutes(180), 180);
      expect(suggestedCookMinutes(300), 300);
      expect(suggestedCookMinutes(420), 300);
      expect(suggestedCookMinutes(null), defaultBookingCookMinutes);
      expect(suggestedCookMinutes(10), minBookingCookMinutes);
    });

    test('de a 30, entre 30 y 300', () {
      expect(steppedCookMinutes(240, 1), 270);
      expect(steppedCookMinutes(240, -1), 210);
      expect(steppedCookMinutes(300, 1), 300);
      expect(steppedCookMinutes(30, -1), 30);
      // Una estimación que no es múltiplo de 30 vuelve a la grilla.
      expect(steppedCookMinutes(195, 1), 210);
      expect(steppedCookMinutes(195, -1), 180);
    });
  });

  group('precio que se propone', () {
    const weekly = RequestEstimate(
      weeks: 4,
      autoPrice: true,
      weeklyServiceCents: 14000,
      serviceCents: 56000,
      savingsCents: 4000,
      weeklyRateCents: 15000,
      weeklyRateDiscountedCents: 14000,
      weeklyDiscountMinWeeks: 4,
    );

    test(
      'con las semanas de la estimación, su precio (el que vio la clienta)',
      () {
        expect(suggestedServiceCents(weekly, weeks: 4), 56000);
      },
    );

    test('con otras semanas, las tarifas guardadas: 150 € o 140 € desde 4', () {
      expect(suggestedServiceCents(weekly, weeks: 1), 15000);
      expect(suggestedServiceCents(weekly, weeks: 3), 45000);
      expect(suggestedServiceCents(weekly, weeks: 8), 112000);
    });

    test('sin precio automático (más personas o una sesión extra): vacío', () {
      const unpriced = RequestEstimate(
        weeks: 2,
        autoPrice: false,
        reason: NoAutoPriceReason.people,
        weeklyRateCents: 15000,
        weeklyRateDiscountedCents: 14000,
        weeklyDiscountMinWeeks: 4,
      );
      expect(suggestedServiceCents(unpriced, weeks: 2), isNull);
      expect(suggestedServiceCents(null, weeks: 1), isNull);
    });

    test('sin tarifas guardadas, solo con las mismas semanas', () {
      const noRates = RequestEstimate(
        weeks: 2,
        autoPrice: true,
        serviceCents: 30000,
      );
      expect(suggestedServiceCents(noRates, weeks: 2), 30000);
      expect(suggestedServiceCents(noRates, weeks: 3), isNull);
      // Una de antes del precio por semana: una semana, su servicio.
      const legacy = RequestEstimate(serviceCents: 7800, totalCents: 14100);
      expect(suggestedServiceCents(legacy, weeks: 1), 7800);
      expect(suggestedServiceCents(legacy, weeks: 2), isNull);
    });

    test('parte de cada semana: exacta o la primera, como split_cents', () {
      expect(weeklyShare(56000, 4), (firstWeekCents: 14000, even: true));
      expect(weeklyShare(50000, 3), (firstWeekCents: 16667, even: false));
      expect(weeklyShare(0, 2), (firstWeekCents: 0, even: true));
    });
  });

  group('horas de llegada', () {
    test('la sugerida y las siguientes cada media hora', () {
      expect(
        arrivalOptions(suggested: const ClockTime.hm(10, 0))
            .map((t) => t.toHhMm()),
        ['10:00', '10:30', '11:00', '11:30', '12:00'],
      );
    });

    test('sin sugerida (día sin horario), desde las 10:00', () {
      expect(arrivalOptions().first, defaultBookingArrival);
      expect(defaultBookingArrival, const ClockTime.hm(10, 0));
    });

    test('la elegida con «Otra hora» se suma, en orden', () {
      expect(
        arrivalOptions(
          suggested: const ClockTime.hm(10, 0),
          selected: const ClockTime.hm(8, 45),
        ).map((t) => t.toHhMm()),
        ['08:45', '10:00', '10:30', '11:00', '11:30', '12:00'],
      );
      expect(
        arrivalOptions(
          suggested: const ClockTime.hm(10, 0),
          selected: const ClockTime.hm(11, 0),
        ),
        hasLength(5),
      );
    });

    test('no pasa de la medianoche', () {
      expect(
        arrivalOptions(suggested: const ClockTime.hm(23, 0))
            .map((t) => t.toHhMm()),
        ['23:00', '23:30'],
      );
    });
  });
}

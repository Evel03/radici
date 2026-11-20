// Reglas de la hoja «Confirmar reserva»: semanas y fechas cada 7 días, lo que
// impide mandar una fecha, los minutos con tope de 360, el precio que se
// propone y las horas de llegada.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/client_fixtures.dart';
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
    test('los de la estimación, con tope de 360', () {
      expect(suggestedCookMinutes(180), 180);
      expect(suggestedCookMinutes(360), 360);
      expect(suggestedCookMinutes(420), 360);
      expect(suggestedCookMinutes(null), defaultBookingCookMinutes);
      expect(suggestedCookMinutes(10), minBookingCookMinutes);
    });

    test('de a 30, entre 30 y 360', () {
      expect(steppedCookMinutes(240, 1), 270);
      expect(steppedCookMinutes(240, -1), 210);
      expect(steppedCookMinutes(300, 1), 330);
      expect(steppedCookMinutes(360, 1), 360);
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

    test('el descuento vale desde 4 semanas, incluida (como calcQuote)', () {
      // Un pedido de 2 semanas que Evelyn pasa a 4: el «mes» de 560 €, no 600.
      final twoWeeks = fourWeeksEstimate.copyWith(weeks: 2, serviceCents: 30000);
      expect(suggestedServiceCents(twoWeeks, weeks: 4), 56000);
      expect(suggestedServiceCents(twoWeeks, weeks: 3), 45000);
      expect(suggestedServiceCents(twoWeeks, weeks: 5), 70000);
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
      const legacy = RequestEstimate(serviceCents: 7800);
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

    test('sin sugerida (día sin horario), desde las 9:00', () {
      expect(arrivalOptions().first, defaultBookingArrival);
      expect(defaultBookingArrival, const ClockTime.hm(9, 0));
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

  group('reserva a mano', () {
    test('empieza con 4 semanas y el hogar de la calculadora (2 + 2, 5 días, cena)', () {
      expect(defaultManualBookingWeeks, 4);
      expect(
        defaultManualHousehold,
        const BookingHousehold(adults: 2, kids: 2, days: 5, meals: [Meal.dinner]),
      );
    });

    test('la estimación del hogar: 2 + 2, 5 días y cena dan 180 min, 20 porciones y 63 € de compra', () {
      expect(
        manualBookingEstimate(defaultManualHousehold),
        (cookMinutes: 180, portions: 20, groceriesEstCents: 6300),
      );
      // Con almuerzo y cena, el doble de porciones; los minutos, con tope de 300.
      final both = manualBookingEstimate(
        defaultManualHousehold.withMeal(Meal.lunch, true),
      );
      expect(both.portions, 40);
      expect(both.cookMinutes, lessThanOrEqualTo(maxBookingCookMinutes));
      final big = manualBookingEstimate(
        const BookingHousehold(adults: 30, kids: 30, days: 7, meals: [Meal.lunch, Meal.dinner]),
      );
      expect(big.cookMinutes, maxBookingCookMinutes);
    });
  });

  group('hogar de la reserva (BookingHousehold)', () {
    const household = BookingHousehold(adults: 1, kids: 0, days: 1, meals: [Meal.dinner]);

    test('no baja de 1 persona ni de 1 día, no pasa de 30 ni de 7', () {
      expect(household.canDecrement(HouseholdCounter.adults), isFalse);
      expect(household.canDecrement(HouseholdCounter.kids), isFalse);
      expect(household.canDecrement(HouseholdCounter.days), isFalse);
      expect(household.stepped(HouseholdCounter.adults, -1), household);
      expect(household.stepped(HouseholdCounter.kids, 1).kids, 1);
      final withKid = household.stepped(HouseholdCounter.kids, 1);
      expect(withKid.canDecrement(HouseholdCounter.adults), isTrue);
      expect(withKid.stepped(HouseholdCounter.adults, -1).adults, 0);

      const full = BookingHousehold(adults: 30, kids: 30, days: 7, meals: [Meal.lunch]);
      expect(full.canIncrement(HouseholdCounter.adults), isFalse);
      expect(full.canIncrement(HouseholdCounter.kids), isFalse);
      expect(full.canIncrement(HouseholdCounter.days), isFalse);
      expect(full.stepped(HouseholdCounter.days, 1), full);
      expect(household.valueOf(HouseholdCounter.days), 1);
    });

    test('nunca queda sin comidas; las comidas, en orden canónico', () {
      expect(household.withMeal(Meal.dinner, false), household);
      final both = household.withMeal(Meal.lunch, true);
      expect(both.canonicalMeals, [Meal.lunch, Meal.dinner]);
      expect(both.withMeal(Meal.dinner, false).canonicalMeals, [Meal.lunch]);
      expect(both.withMeal(Meal.lunch, true), both);
    });

    test('clamped lleva cualquier valor leído a los límites del contrato', () {
      expect(
        BookingHousehold.clamped(adults: 40, kids: -2, days: 9, meals: const []),
        const BookingHousehold(adults: 30, kids: 0, days: 7, meals: [Meal.dinner]),
      );
      expect(
        BookingHousehold.clamped(adults: 0, kids: 0, days: 0, meals: const [Meal.lunch]),
        const BookingHousehold(adults: 1, kids: 0, days: 1, meals: [Meal.lunch]),
      );
    });

    test('toQuoteInput: una semana de comidas', () {
      final input = defaultManualHousehold.toQuoteInput(weeks: 3);
      expect(input.adults, 2);
      expect(input.kids, 2);
      expect(input.days, 5);
      expect(input.meals, 1);
      expect(input.weeks, 3);
    });
  });

  group('hogar de una ficha (householdFor)', () {
    test('el del último pedido semanal, ajustado a los límites', () {
      expect(
        householdFor(
          latestWeekly: buildLatestWeekly(
            adults: 3,
            kids: 1,
            days: 4,
            meals: const [Meal.lunch, Meal.dinner],
          ),
          fichaAdults: 1,
          fichaKids: 0,
        ),
        const BookingHousehold(adults: 3, kids: 1, days: 4, meals: [Meal.lunch, Meal.dinner]),
      );
      expect(
        householdFor(
          latestWeekly: buildLatestWeekly(adults: 45, kids: 0, days: 5),
          fichaAdults: 1,
          fichaKids: 0,
        ).adults,
        30,
      );
    });

    test('sin pedido semanal: adultos y niños de la ficha, 5 días y cena', () {
      expect(
        householdFor(fichaAdults: 2, fichaKids: 1),
        const BookingHousehold(adults: 2, kids: 1, days: 5, meals: [Meal.dinner]),
      );
      // Una ficha con 0 y 0 (clients solo exige >= 0): 1 adulto.
      expect(householdFor(fichaAdults: 0, fichaKids: 0).adults, 1);
    });

    test('nunca el de un evento (el caso Bonetti) ni el de un cambio sin hogar (el caso Chiara)', () {
      final bonettiEvent = buildLatestWeekly(
        type: RequestType.extra,
        adults: 10,
        kids: 6,
        days: 1,
      );
      expect(
        householdFor(latestWeekly: bonettiEvent, fichaAdults: 2, fichaKids: 1),
        const BookingHousehold(adults: 2, kids: 1, days: 5, meals: [Meal.dinner]),
      );
      final chiaraChange = buildLatestWeekly(
        type: RequestType.change,
        adults: null,
        kids: null,
        days: null,
        meals: const [],
      );
      expect(
        householdFor(latestWeekly: chiaraChange, fichaAdults: 1, fichaKids: 0),
        const BookingHousehold(adults: 1, kids: 0, days: 5, meals: [Meal.dinner]),
      );
      // Un pedido semanal sin días ni comidas tampoco describe la casa.
      expect(
        householdFor(
          latestWeekly: buildLatestWeekly(days: null),
          fichaAdults: 2,
          fichaKids: 2,
        ),
        const BookingHousehold(adults: 2, kids: 2, days: 5, meals: [Meal.dinner]),
      );
    });
  });

  group('llegada de hoy que ya pasó (arrivalPassedToday)', () {
    final day = CalendarDate(2026, 11, 17);

    test('hoy a las 10:00 con las 18:00, sí; con las 9:00, no; mañana, no', () {
      expect(
        arrivalPassedToday(
          date: day,
          start: const ClockTime.hm(10, 0),
          today: day,
          now: const ClockTime.hm(18, 0),
        ),
        isTrue,
      );
      expect(
        arrivalPassedToday(
          date: day,
          start: const ClockTime.hm(10, 0),
          today: day,
          now: const ClockTime.hm(9, 0),
        ),
        isFalse,
      );
      expect(
        arrivalPassedToday(
          date: day.addDays(1),
          start: const ClockTime.hm(10, 0),
          today: day,
          now: const ClockTime.hm(18, 0),
        ),
        isFalse,
      );
      // Una fecha pasada ya la marca el servidor («Data passata»).
      expect(
        arrivalPassedToday(
          date: day.addDays(-1),
          start: const ClockTime.hm(10, 0),
          today: day,
          now: const ClockTime.hm(18, 0),
        ),
        isFalse,
      );
    });
  });
}

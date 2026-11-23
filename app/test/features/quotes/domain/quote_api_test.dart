// Lo que la app manda a POST chef/quotes, /quotes/price y /quotes/withdraw
// (contrato chef-api §14) y cómo lee lo que devuelven: entero o nada.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/quotes/domain/quote_api.dart';
import 'package:radici/features/requests/domain/chef_request.dart'
    show ClientLocale, Meal, RequestType;

import '../../../support/quote_fixtures.dart';

void main() {
  final monday = CalendarDate(2026, 11, 30);
  final dates = [monday, monday.addDays(7)];

  group('el cuerpo de POST chef/quotes', () {
    test('las claves del contrato, con la hora y el precio', () {
      final body = CreateQuoteRequest(
        requestId: 'req-1',
        dates: dates,
        start: const ClockTime.hm(10, 0),
        cookMinutes: 180,
        portions: 20,
        serviceTotalCents: 28000,
      ).toBody();
      expect(body, {
        'requestId': 'req-1',
        'dates': ['2026-11-30', '2026-12-07'],
        'start': '10:00',
        'cookMinutes': 180,
        'portions': 20,
        'serviceTotalCents': 28000,
        'dryRun': false,
      });
    });

    test('el dryRun sin hora ni precio no los manda', () {
      final body = CreateQuoteRequest(
        requestId: 'req-1',
        dates: dates,
        cookMinutes: 180,
        dryRun: true,
      ).toBody();
      expect(body.keys, ['requestId', 'dates', 'cookMinutes', 'dryRun']);
    });

    test('desde la reserva de la hoja: lo mismo, sin la clave ni el hogar', () {
      final booking = BookingRequest(
        requestId: 'req-1',
        dates: dates,
        start: const ClockTime.hm(9, 30),
        cookMinutes: 240,
        portions: 12,
        serviceTotalCents: 50000,
        requestKey: 'key-1',
      );
      final request = CreateQuoteRequest.fromBooking(booking);
      expect(request.requestId, 'req-1');
      expect(request.dates, dates);
      expect(request.start, const ClockTime.hm(9, 30));
      expect(request.cookMinutes, 240);
      expect(request.portions, 12);
      expect(request.serviceTotalCents, 50000);
      expect(request.dryRun, isFalse);
      expect(request.toBody().containsKey('requestKey'), isFalse);
    });

    test('una reserva a mano (sin pedido) no es un presupuesto', () {
      final manual = BookingRequest(
        clientId: 'c',
        type: RequestType.week,
        household: const BookingHousehold(
          adults: 2,
          kids: 0,
          days: 5,
          meals: [Meal.dinner],
        ),
        locale: ClientLocale.it,
        dates: dates,
        cookMinutes: 60,
      );
      expect(() => CreateQuoteRequest.fromBooking(manual), throwsArgumentError);
    });

    test('toString solo dice cuántas fechas', () {
      expect(
        '${CreateQuoteRequest(requestId: 'req-1', dates: dates, cookMinutes: 60)}',
        'CreateQuoteRequest(dates: 2, dryRun: false)',
      );
    });
  });

  group('la respuesta de POST chef/quotes', () {
    Map<String, Object?> week({
      String date = '2026-11-30',
      String? start = '10:00',
      String status = 'ok',
      String? sessionId,
      int cents = 14000,
    }) => {
      'date': date,
      'start': start,
      'cookMinutes': 180,
      'status': status,
      'suggestedStart': '09:00',
      'serviceCents': cents,
      'sessionId': sessionId,
    };

    test('el dryRun: el estado de cada fecha, sin presupuesto ni sesiones', () {
      final draft = QuoteDraft.fromResponse({
        'dryRun': true,
        'quoteId': null,
        'requestId': 'req-1',
        'clientId': quoteClientId,
        'holdUntil': null,
        'weeks': [
          week(status: 'busy'),
          week(date: '2026-12-07', status: 'closed', start: null),
        ],
      });
      expect(draft.dryRun, isTrue);
      expect(draft.quoteId, isNull);
      expect(draft.weeks.map((w) => w.status), [
        BookingDayStatus.busy,
        BookingDayStatus.closed,
      ]);
      expect(draft.weeks.last.start, isNull);
      expect(draft.firstSessionId, isNull);
      final result = draft.toBookingResult();
      expect(result.dryRun, isTrue);
      expect(result.duplicate, isFalse);
      expect(result.weeks, draft.weeks);
    });

    test('creado: cada semana retenida con su sesión («free» queda en ok) y el plazo del borrador', () {
      final draft = QuoteDraft.fromResponse({
        'dryRun': false,
        'quoteId': testQuoteId,
        'requestId': 'req-1',
        'clientId': quoteClientId,
        'holdUntil': '2026-11-24T09:00:00.123456+00:00',
        'weeks': [
          week(status: 'free', sessionId: quoteSessionId(1), cents: 14001),
          week(
            date: '2026-12-07',
            status: 'free',
            sessionId: quoteSessionId(2),
          ),
        ],
      });
      expect(draft.quoteId, testQuoteId);
      expect(draft.holdUntil, DateTime.utc(2026, 11, 24, 9, 0, 0, 123, 456));
      expect(draft.weeks.map((w) => w.status), [
        BookingDayStatus.ok,
        BookingDayStatus.ok,
      ]);
      expect(draft.firstSessionId, quoteSessionId(1));
      expect(draft.toBookingResult(duplicate: true).duplicate, isTrue);
    });

    test('con otra forma, FormatException: nunca un presupuesto a medias', () {
      final created = {
        'dryRun': false,
        'quoteId': testQuoteId,
        'requestId': 'req-1',
        'clientId': quoteClientId,
        'holdUntil': '2026-11-24T09:00:00+00:00',
        'weeks': [week(status: 'free', sessionId: quoteSessionId(1))],
      };
      final dry = {
        'dryRun': true,
        'quoteId': null,
        'requestId': 'req-1',
        'clientId': quoteClientId,
        'holdUntil': null,
        'weeks': [week()],
      };
      for (final broken in <Object?>[
        null,
        {...created, 'quoteId': null},
        {...created, 'holdUntil': null},
        {
          ...created,
          'weeks': [week(sessionId: quoteSessionId(1))],
        },
        {
          ...created,
          'weeks': [week(status: 'free')],
        },
        {...created, 'weeks': <Object>[]},
        {...dry, 'quoteId': testQuoteId},
        {
          ...dry,
          'weeks': [week(status: 'free')],
        },
        {
          ...dry,
          'weeks': [week(sessionId: quoteSessionId(1))],
        },
        {...dry, 'requestId': null},
      ]) {
        expect(
          () => QuoteDraft.fromResponse(broken),
          throwsFormatException,
          reason: '$broken',
        );
      }
    });
  });

  group('otro precio', () {
    test('el cuerpo y los términos de ahora', () {
      expect(quotePriceBody(quoteId: testQuoteId, serviceTotalCents: 42001), {
        'quoteId': testQuoteId,
        'serviceTotalCents': 42001,
      });
      final terms = quoteTermsFromPriceResponse(
        quoteTermsJson(),
        quoteId: testQuoteId,
        totalCents: 56000,
      );
      expect(terms.weeks, hasLength(4));
    });

    test(
      'de otro presupuesto, con otro total o sin semanas: FormatException',
      () {
        expect(
          () => quoteTermsFromPriceResponse(
            quoteTermsJson(quoteId: 'otro'),
            quoteId: testQuoteId,
            totalCents: 56000,
          ),
          throwsFormatException,
        );
        expect(
          () => quoteTermsFromPriceResponse(
            quoteTermsJson(),
            quoteId: testQuoteId,
            totalCents: 1,
          ),
          throwsFormatException,
        );
        expect(
          () => quoteTermsFromPriceResponse(
            {'quoteId': testQuoteId, 'totalCents': 0, 'weeks': <Object>[]},
            quoteId: testQuoteId,
            totalCents: 0,
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('retirarlo', () {
    test('el cuerpo y la respuesta', () {
      expect(quoteWithdrawBody(testQuoteId), {'quoteId': testQuoteId});
      expect(
        withdrawnQuoteFromResponse({
          'quoteId': testQuoteId,
          'requestId': 'req-1',
          'already': false,
          'cancelled': 4,
        }),
        (
          quoteId: testQuoteId,
          requestId: 'req-1',
          already: false,
          cancelled: 4,
        ),
      );
    });

    test('con otra forma: FormatException', () {
      for (final broken in <Object?>[
        null,
        {
          'quoteId': testQuoteId,
          'requestId': 'req-1',
          'already': 'no',
          'cancelled': 0,
        },
        {
          'quoteId': testQuoteId,
          'requestId': 'req-1',
          'already': false,
          'cancelled': -1,
        },
        {'quoteId': testQuoteId, 'already': false, 'cancelled': 0},
      ]) {
        expect(() => withdrawnQuoteFromResponse(broken), throwsFormatException);
      }
    });
  });
}

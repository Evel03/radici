// Cuerpo de POST chef/bookings y lectura de su respuesta (contrato
// docs/contracts/chef-api.md §4).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking.dart';

void main() {
  const requestId = 'b0000000-0000-4000-8000-0000000000aa';
  final monday = CalendarDate(2026, 11, 23);

  group('BookingRequest.toBody', () {
    test('la confirmación lleva todo: fechas, hora, minutos, precio, clave y dryRun false', () {
      final body = BookingRequest(
        requestId: requestId,
        dates: [monday, monday.addDays(7)],
        start: const ClockTime.hm(10, 0),
        cookMinutes: 240,
        portions: 20,
        groceriesEstCents: 6300,
        serviceTotalCents: 30000,
        requestKey: '7e5b3000-0000-4000-8000-000000000001',
      ).toBody();
      expect(body, {
        'requestId': requestId,
        'dates': ['2026-11-23', '2026-11-30'],
        'start': '10:00',
        'cookMinutes': 240,
        'portions': 20,
        'groceriesEstCents': 6300,
        'serviceTotalCents': 30000,
        'requestKey': '7e5b3000-0000-4000-8000-000000000001',
        'dryRun': false,
      });
    });

    test('el dryRun puede ir sin hora, sin precio y sin clave', () {
      final body = BookingRequest(
        requestId: requestId,
        dates: [monday],
        cookMinutes: 180,
        dryRun: true,
      ).toBody();
      expect(body, {
        'requestId': requestId,
        'dates': ['2026-11-23'],
        'cookMinutes': 180,
        'dryRun': true,
      });
    });
  });

  group('BookingResult.fromResponse', () {
    Map<String, Object?> week({
      String date = '2026-11-23',
      Object? start = '10:00',
      Object? status = 'ok',
      Object? suggestedStart = '10:00',
      Object? sessionId,
    }) => {
      'date': date,
      'start': start,
      'cookMinutes': 240,
      'status': status,
      'suggestedStart': suggestedStart,
      'serviceCents': 14000,
      'sessionId': sessionId,
    };

    test('lee la reserva creada', () {
      final result = BookingResult.fromResponse({
        'dryRun': false,
        'duplicate': false,
        'requestId': requestId,
        'clientId': 'c1000000-0000-4000-8000-000000000003',
        'weeks': [
          week(sessionId: 's1'),
          week(date: '2026-11-30', status: 'blocked', sessionId: 's2'),
        ],
      });
      expect(result.dryRun, isFalse);
      expect(result.duplicate, isFalse);
      expect(result.requestId, requestId);
      expect(result.weeks, [
        BookingWeek(
          date: monday,
          start: const ClockTime.hm(10, 0),
          cookMinutes: 240,
          status: BookingDayStatus.ok,
          suggestedStart: const ClockTime.hm(10, 0),
          serviceCents: 14000,
          sessionId: 's1',
        ),
        BookingWeek(
          date: monday.addDays(7),
          start: const ClockTime.hm(10, 0),
          cookMinutes: 240,
          status: BookingDayStatus.blocked,
          suggestedStart: const ClockTime.hm(10, 0),
          serviceCents: 14000,
          sessionId: 's2',
        ),
      ]);
    });

    test('el dryRun de un día sin horario: sin hora ni sugerida', () {
      final result = BookingResult.fromResponse({
        'dryRun': true,
        'duplicate': false,
        'requestId': requestId,
        'clientId': null,
        'weeks': [week(start: null, status: 'closed', suggestedStart: null)],
      });
      expect(result.dryRun, isTrue);
      expect(result.clientId, isNull);
      expect(result.weeks.single.start, isNull);
      expect(result.weeks.single.suggestedStart, isNull);
      expect(result.weeks.single.status, BookingDayStatus.closed);
    });

    test(
      'todos los estados del contrato, en orden de prioridad; solo busy impide',
      () {
        expect(BookingDayStatus.values.map((s) => s.name), [
          'busy',
          'past',
          'blocked',
          'closed',
          'outside',
          'ok',
        ]);
        expect(
          [
            for (final s in BookingDayStatus.values)
              if (s.blocksBooking) s,
          ],
          [BookingDayStatus.busy],
        );
      },
    );

    test('una respuesta con otra forma lanza FormatException', () {
      final good = {
        'dryRun': true,
        'duplicate': false,
        'requestId': requestId,
        'clientId': null,
        'weeks': [week()],
      };
      for (final bad in <Object?>[
        null,
        'texto',
        <Object?>[],
        {...good, 'dryRun': 'no'},
        {...good, 'weeks': 'x'},
        {...good, 'requestId': 5},
        {
          ...good,
          'weeks': [week(status: 'raro')],
        },
        {
          ...good,
          'weeks': [week(date: '2026-02-30')],
        },
        {
          ...good,
          'weeks': [week(start: '10:00:00')],
        },
        {
          ...good,
          'weeks': [
            {...week(), 'serviceCents': 140.5},
          ],
        },
      ]) {
        expect(
          () => BookingResult.fromResponse(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });
}

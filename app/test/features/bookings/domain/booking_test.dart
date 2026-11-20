// Cuerpo de POST chef/bookings y lectura de su respuesta (contrato
// docs/contracts/chef-api.md §4).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

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
        serviceTotalCents: 30000,
        requestKey: '7e5b3000-0000-4000-8000-000000000001',
      ).toBody();
      expect(body, {
        'requestId': requestId,
        'dates': ['2026-11-23', '2026-11-30'],
        'start': '10:00',
        'cookMinutes': 240,
        'portions': 20,
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

  group('a mano: clientId o newClient (cuerpos 2, 3 y 4 de la especificación)', () {
    const clientId = 'c1000000-0000-4000-8000-000000000003';
    const key = '7e5b3000-0000-4000-8000-000000000002';
    final wednesday = CalendarDate(2026, 11, 18);
    final fourWeeks = [
      for (var week = 0; week < 4; week++) wednesday.addDays(7 * week),
    ];
    const household = BookingHousehold(
      adults: 2,
      kids: 2,
      days: 5,
      meals: [Meal.dinner],
    );
    const householdJson = {
      'adults': 2,
      'kids': 2,
      'days': 5,
      'meals': ['dinner'],
    };
    const giulia = NewClientData(
      name: 'Giulia Rossi',
      phone: '+393331234567',
      zone: 'Città Alta',
      address: 'Via Gombito 12, Bergamo',
    );
    const giuliaJson = {
      'name': 'Giulia Rossi',
      'phone': '+393331234567',
      'zone': 'Città Alta',
      'address': 'Via Gombito 12, Bergamo',
    };

    test('ficha existente: el primer dryRun, sin hora', () {
      final body = BookingRequest(
        clientId: clientId,
        type: RequestType.week,
        household: household,
        locale: ClientLocale.it,
        dates: fourWeeks,
        cookMinutes: 180,
        portions: 20,
        groceriesEstCents: 6300,
        dryRun: true,
      ).toBody();
      expect(body, {
        'clientId': clientId,
        'type': 'week',
        'household': householdJson,
        'locale': 'it',
        'dates': ['2026-11-18', '2026-11-25', '2026-12-02', '2026-12-09'],
        'cookMinutes': 180,
        'portions': 20,
        'groceriesEstCents': 6300,
        'dryRun': true,
      });
    });

    test('ficha existente: la confirmación', () {
      final body = BookingRequest(
        clientId: clientId,
        type: RequestType.week,
        household: household,
        locale: ClientLocale.es,
        dates: fourWeeks,
        start: const ClockTime.hm(10, 0),
        cookMinutes: 180,
        portions: 20,
        groceriesEstCents: 6300,
        serviceTotalCents: 56000,
        requestKey: key,
      ).toBody();
      expect(body, {
        'clientId': clientId,
        'type': 'week',
        'household': householdJson,
        'locale': 'es',
        'dates': ['2026-11-18', '2026-11-25', '2026-12-02', '2026-12-09'],
        'start': '10:00',
        'cookMinutes': 180,
        'portions': 20,
        'groceriesEstCents': 6300,
        'serviceTotalCents': 56000,
        'requestKey': key,
        'dryRun': false,
      });
    });

    test('ficha nueva: newClient completo ya en el dryRun, igual que al confirmar', () {
      BookingRequest manual({required bool dryRun}) => BookingRequest(
        newClient: giulia,
        type: RequestType.week,
        household: household,
        locale: ClientLocale.it,
        dates: [wednesday],
        start: dryRun ? null : const ClockTime.hm(10, 0),
        cookMinutes: 180,
        portions: 20,
        groceriesEstCents: 6300,
        serviceTotalCents: dryRun ? null : 14000,
        requestKey: dryRun ? null : key,
        dryRun: dryRun,
      );
      expect(manual(dryRun: true).toBody(), {
        'newClient': giuliaJson,
        'type': 'week',
        'household': householdJson,
        'locale': 'it',
        'dates': ['2026-11-18'],
        'cookMinutes': 180,
        'portions': 20,
        'groceriesEstCents': 6300,
        'dryRun': true,
      });
      expect(manual(dryRun: false).toBody(), {
        'newClient': giuliaJson,
        'type': 'week',
        'household': householdJson,
        'locale': 'it',
        'dates': ['2026-11-18'],
        'start': '10:00',
        'cookMinutes': 180,
        'portions': 20,
        'groceriesEstCents': 6300,
        'serviceTotalCents': 14000,
        'requestKey': key,
        'dryRun': false,
      });
    });

    test('una ficha nueva solo con el nombre: sin las claves vacías', () {
      final body = BookingRequest(
        newClient: const NewClientData(name: 'Anna'),
        type: RequestType.week,
        household: household,
        locale: ClientLocale.en,
        dates: [wednesday],
        cookMinutes: 180,
        dryRun: true,
      ).toBody();
      expect(body['newClient'], {'name': 'Anna'});
      expect(body.containsKey('portions'), isFalse);
    });

    test('con la hora ya elegida (como «Rinnova»), el primer dryRun la lleva', () {
      final body = BookingRequest(
        clientId: clientId,
        type: RequestType.week,
        household: household,
        locale: ClientLocale.it,
        dates: fourWeeks,
        start: const ClockTime.hm(10, 0),
        cookMinutes: 180,
        portions: 20,
        groceriesEstCents: 6300,
        dryRun: true,
      ).toBody();
      expect(body['start'], '10:00');
      expect(body['dryRun'], isTrue);
      expect(body.containsKey('requestKey'), isFalse);
    });

    test('las comidas van en orden canónico y sin repetir aunque se pasen al revés', () {
      final body = BookingRequest(
        clientId: clientId,
        type: RequestType.week,
        household: const BookingHousehold(
          adults: 1,
          kids: 0,
          days: 7,
          meals: [Meal.dinner, Meal.lunch, Meal.dinner],
        ),
        locale: ClientLocale.it,
        dates: [wednesday],
        cookMinutes: 180,
        dryRun: true,
      ).toBody();
      expect((body['household']! as Map)['meals'], ['lunch', 'dinner']);
    });

    test('una sola clienta: con dos (o ninguna), AssertionError; a mano, con tipo, hogar e idioma', () {
      expect(
        () => BookingRequest(
          requestId: requestId,
          clientId: clientId,
          dates: [wednesday],
          cookMinutes: 180,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => BookingRequest(dates: [wednesday], cookMinutes: 180),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => BookingRequest(
          clientId: clientId,
          dates: [wednesday],
          cookMinutes: 180,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('toString sin el nombre, el teléfono ni la dirección', () {
      final request = BookingRequest(
        newClient: giulia,
        type: RequestType.week,
        household: household,
        locale: ClientLocale.it,
        dates: fourWeeks,
        cookMinutes: 180,
        dryRun: true,
      );
      for (final text in [request.toString(), giulia.toString()]) {
        expect(text, isNot(contains('Giulia')));
        expect(text, isNot(contains('3331234567')));
        expect(text, isNot(contains('Gombito')));
      }
      expect(request.toString(), 'BookingRequest(dates: 4, dryRun: true)');
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
        {...good, 'clientId': 5},
        {...good, 'duplicate': 'x'},
        {
          ...good,
          'weeks': [
            {...week(), 'cookMinutes': '240'},
          ],
        },
        {
          ...good,
          'weeks': [week(sessionId: 5)],
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

  group('lo guardado contra lo que se mandó (un reintento devuelve lo guardado)', () {
    final sent = BookingRequest(
      requestId: requestId,
      dates: [monday, monday.addDays(7)],
      start: const ClockTime.hm(10, 0),
      cookMinutes: 240,
      serviceTotalCents: 30001,
      requestKey: '7e5b3000-0000-4000-8000-000000000001',
    );

    BookingResult saved({
      List<CalendarDate>? dates,
      ClockTime start = const ClockTime.hm(10, 0),
      int cookMinutes = 240,
      List<int> cents = const [15001, 15000],
    }) => BookingResult(
      dryRun: false,
      duplicate: true,
      requestId: requestId,
      weeks: [
        for (final (i, date) in (dates ?? sent.dates).indexed)
          BookingWeek(
            date: date,
            start: start,
            cookMinutes: cookMinutes,
            status: BookingDayStatus.ok,
            serviceCents: cents[i],
            sessionId: 's$i',
          ),
      ],
    );

    test('igual: las mismas fechas, hora, minutos y total (repartido)', () {
      expect(saved().matches(sent), isTrue);
    });

    test('otro precio, otros minutos, otra hora u otras fechas: no', () {
      expect(saved(cents: const [12500, 12500]).matches(sent), isFalse);
      expect(saved(cookMinutes: 200).matches(sent), isFalse);
      expect(saved(start: const ClockTime.hm(11, 0)).matches(sent), isFalse);
      expect(
        saved(dates: [monday, monday.addDays(8)]).matches(sent),
        isFalse,
      );
      expect(saved(dates: [monday], cents: const [30001]).matches(sent), isFalse);
    });
  });
}

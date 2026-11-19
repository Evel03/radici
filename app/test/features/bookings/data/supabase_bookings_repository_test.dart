// La primera llamada de la app a una Edge Function, con el SDK real contra un
// servidor HTTP simulado: POST a /functions/v1/chef/bookings con la sesión de
// Evelyn y la región en la URL (nunca la cabecera x-region, que CORS no
// permite), la respuesta leída y cada error traducido a BookingFailure.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/supabase_http_fake.dart';

Matcher _failure(
  BookingFailureKind kind, {
  CalendarDate? date,
  String? status,
}) => throwsA(
  isA<BookingFailure>()
      .having((f) => f.kind, 'kind', kind)
      .having((f) => f.date, 'date', date)
      .having((f) => f.requestStatus, 'requestStatus', status),
);

void main() {
  const requestId = 'b0000000-0000-4000-8000-0000000000aa';
  const key = '7e5b3000-0000-4000-8000-000000000001';
  final monday = CalendarDate(2026, 11, 23);

  late FakeSupabaseHttp server;
  late SupabaseBookingsRepository repository;

  BookingRequest confirmation() => BookingRequest(
    requestId: requestId,
    dates: [monday, monday.addDays(7)],
    start: const ClockTime.hm(10, 0),
    cookMinutes: 240,
    portions: 20,
    serviceTotalCents: 30000,
    requestKey: key,
  );

  Map<String, Object?> created({bool duplicate = false}) => {
    'dryRun': false,
    'duplicate': duplicate,
    'requestId': requestId,
    'clientId': 'c1000000-0000-4000-8000-000000000003',
    'weeks': [
      for (final (i, date) in ['2026-11-23', '2026-11-30'].indexed)
        {
          'date': date,
          'start': '10:00',
          'cookMinutes': 240,
          'status': 'ok',
          'suggestedStart': '10:00',
          'serviceCents': 15000,
          'sessionId': 's$i',
        },
    ],
  };

  setUp(() async {
    server = FakeSupabaseHttp(
      (_) async => jsonResponse(created(), status: 201),
    );
    repository = SupabaseBookingsRepository(server.client);
    await signInFake(server);
  });

  tearDown(() => server.dispose());

  test('POST a /functions/v1/chef/bookings con la sesión, la región en la URL y el cuerpo del contrato', () async {
    final result = await repository.createBooking(confirmation());

    expect(result.dryRun, isFalse);
    expect(result.weeks.map((w) => w.sessionId), ['s0', 's1']);
    expect(result.weeks.first.status, BookingDayStatus.ok);

    final request = server.last;
    expect(request.method, 'POST');
    expect(request.url.path, '/functions/v1/chef/bookings');
    expect(request.url.queryParameters, {
      'forceFunctionRegion': 'eu-central-1',
    });
    // La sesión de Evelyn, no la clave publicable, y la clave en apikey.
    expect(request.headers['Authorization'], 'Bearer ${fakeJwt('user-1')}');
    expect(request.headers['apikey'], 'sb_publishable_test');
    expect(request.headers['Content-Type'], startsWith('application/json'));
    // x-region no: el preflight de CORS no la permite.
    expect(
      request.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('x-region')),
    );
    expect(jsonBodyOf(request), {
      'requestId': requestId,
      'dates': ['2026-11-23', '2026-11-30'],
      'start': '10:00',
      'cookMinutes': 240,
      'portions': 20,
      'serviceTotalCents': 30000,
      'requestKey': key,
      'dryRun': false,
    });
  });

  test('el dryRun devuelve el estado de cada fecha', () async {
    server.handler = (_) async => jsonResponse({
      'dryRun': true,
      'duplicate': false,
      'requestId': requestId,
      'clientId': 'c1000000-0000-4000-8000-000000000003',
      'weeks': [
        {
          'date': '2026-11-23',
          'start': '10:00',
          'cookMinutes': 240,
          'status': 'busy',
          'suggestedStart': '10:00',
          'serviceCents': 0,
          'sessionId': null,
        },
      ],
    });

    final result = await repository.createBooking(
      BookingRequest(
        requestId: requestId,
        dates: [monday],
        cookMinutes: 240,
        dryRun: true,
      ),
    );

    expect(result.dryRun, isTrue);
    expect(result.weeks.single.status, BookingDayStatus.busy);
    expect(result.weeks.single.sessionId, isNull);
    expect(jsonBodyOf(server.last), {
      'requestId': requestId,
      'dates': ['2026-11-23'],
      'cookMinutes': 240,
      'dryRun': true,
    });
  });

  test('un 409 slotTaken pasa a slotTaken con la fecha del choque', () async {
    server.handler = (_) async =>
        jsonResponse({'error': 'slotTaken', 'date': '2026-11-30'}, status: 409);
    await expectLater(
      repository.createBooking(confirmation()),
      _failure(BookingFailureKind.slotTaken, date: CalendarDate(2026, 11, 30)),
    );
  });

  test('el reintento después de una falla manda la misma clave, y el servidor no duplica', () async {
    var calls = 0;
    server.handler = (_) async {
      calls++;
      // La primera vez la base no responde; la segunda devuelve la reserva
      // (la clave y el estado del pedido dicen que es la misma).
      return calls == 1
          ? jsonResponse({'error': 'unavailable'}, status: 503)
          : jsonResponse(created(duplicate: true), status: 201);
    };

    await expectLater(
      repository.createBooking(confirmation()),
      _failure(BookingFailureKind.unavailable),
    );
    final retry = await repository.createBooking(confirmation());

    expect(retry.duplicate, isTrue);
    expect(server.requests, hasLength(2));
    expect(server.requests.map((r) => jsonBodyOf(r)['requestKey']), [key, key]);
  });

  group('a mano (contrato §4: clientId o newClient, con type, household y locale)', () {
    const clientId = 'c1000000-0000-4000-8000-000000000003';
    const household = BookingHousehold(
      adults: 2,
      kids: 2,
      days: 5,
      meals: [Meal.dinner],
    );

    test('ficha existente: el cuerpo exacto que llega a la función', () async {
      await repository.createBooking(
        BookingRequest(
          clientId: clientId,
          type: RequestType.week,
          household: household,
          locale: ClientLocale.es,
          dates: [monday, monday.addDays(7)],
          start: const ClockTime.hm(10, 0),
          cookMinutes: 180,
          portions: 20,
          serviceTotalCents: 28000,
          requestKey: key,
        ),
      );
      expect(server.last.url.path, '/functions/v1/chef/bookings');
      expect(jsonBodyOf(server.last), {
        'clientId': clientId,
        'type': 'week',
        'household': {
          'adults': 2,
          'kids': 2,
          'days': 5,
          'meals': ['dinner'],
        },
        'locale': 'es',
        'dates': ['2026-11-23', '2026-11-30'],
        'start': '10:00',
        'cookMinutes': 180,
        'portions': 20,
        'serviceTotalCents': 28000,
        'requestKey': key,
        'dryRun': false,
      });
    });

    test('ficha nueva: el dryRun lleva newClient completo; la respuesta, sin pedido ni ficha', () async {
      server.handler = (_) async => jsonResponse({
        'dryRun': true,
        'duplicate': false,
        'requestId': null,
        'clientId': null,
        'weeks': [
          {
            'date': '2026-11-23',
            'start': '10:00',
            'cookMinutes': 180,
            'status': 'ok',
            'suggestedStart': '10:00',
            'serviceCents': 0,
            'sessionId': null,
          },
        ],
      });
      final result = await repository.createBooking(
        BookingRequest(
          newClient: const NewClientData(
            name: 'Giulia Rossi',
            phone: '+393331234567',
            zone: 'Città Alta',
            address: 'Via Gombito 12, Bergamo',
          ),
          type: RequestType.week,
          household: household,
          locale: ClientLocale.it,
          dates: [monday],
          cookMinutes: 180,
          portions: 20,
          dryRun: true,
        ),
      );
      expect(result.requestId, isNull);
      expect(result.clientId, isNull);
      expect(jsonBodyOf(server.last), {
        'newClient': {
          'name': 'Giulia Rossi',
          'phone': '+393331234567',
          'zone': 'Città Alta',
          'address': 'Via Gombito 12, Bergamo',
        },
        'type': 'week',
        'household': {
          'adults': 2,
          'kids': 2,
          'days': 5,
          'meals': ['dinner'],
        },
        'locale': 'it',
        'dates': ['2026-11-23'],
        'cookMinutes': 180,
        'portions': 20,
        'dryRun': true,
      });
    });

    test('un 400 de la ficha nueva deja los nombres de los campos (newClient.phone)', () async {
      server.handler = (_) async => jsonResponse({
        'errors': {'newClient.phone': 'invalid'},
      }, status: 400);
      await expectLater(
        repository.createBooking(
          BookingRequest(
            newClient: const NewClientData(name: 'Giulia', phone: '+39'),
            type: RequestType.week,
            household: household,
            locale: ClientLocale.it,
            dates: [monday],
            cookMinutes: 180,
            dryRun: true,
          ),
        ),
        throwsA(
          isA<BookingFailure>()
              .having((f) => f.kind, 'kind', BookingFailureKind.invalid)
              .having((f) => f.fields, 'fields', {'newClient.phone'}),
        ),
      );
    });

    test('un 404 clientNotFound es notFound', () async {
      server.handler = (_) async =>
          jsonResponse({'error': 'clientNotFound'}, status: 404);
      await expectLater(
        repository.createBooking(
          BookingRequest(
            clientId: clientId,
            type: RequestType.week,
            household: household,
            locale: ClientLocale.it,
            dates: [monday],
            cookMinutes: 180,
            dryRun: true,
          ),
        ),
        _failure(BookingFailureKind.notFound),
      );
    });
  });

  group('cada error, a su tipo', () {
    final cases = <(String, int, Object?, Matcher)>[
      (
        'weekTaken con la fecha',
        409,
        {'error': 'weekTaken', 'date': '2026-11-23'},
        _failure(
          BookingFailureKind.weekTaken,
          date: CalendarDate(2026, 11, 23),
        ),
      ),
      (
        'requestNotNew con el estado',
        409,
        {'error': 'requestNotNew', 'status': 'accepted'},
        _failure(BookingFailureKind.requestNotNew, status: 'accepted'),
      ),
      (
        'otro 409',
        409,
        {'error': 'conflict'},
        _failure(BookingFailureKind.conflict),
      ),
      (
        'slotTaken sin una fecha válida',
        409,
        {'error': 'slotTaken', 'date': 'mañana'},
        _failure(BookingFailureKind.conflict),
      ),
      (
        'validación por campo, con la fecha',
        400,
        {
          'errors': {'dates': 'sameWeek'},
          'date': '2026-11-29',
        },
        throwsA(
          isA<BookingFailure>()
              .having((f) => f.kind, 'kind', BookingFailureKind.invalid)
              .having((f) => f.fields, 'fields', {'dates'})
              .having((f) => f.date, 'date', CalendarDate(2026, 11, 29)),
        ),
      ),
      (
        'sin sesión válida',
        401,
        {'error': 'unauthorized'},
        _failure(BookingFailureKind.unauthorized),
      ),
      (
        'no es la cocinera ni un colaborador suyo',
        403,
        {'error': 'forbidden'},
        _failure(BookingFailureKind.forbidden),
      ),
      (
        'el pedido no existe',
        404,
        {'error': 'requestNotFound'},
        _failure(BookingFailureKind.notFound),
      ),
      // La función no está desplegada: la plataforma responde 404 con su cuerpo.
      (
        'función inexistente',
        404,
        {'message': 'Not found'},
        _failure(BookingFailureKind.unavailable),
      ),
      // Un cuerpo que la app no debería mandar: no se arregla reintentando.
      (
        'otro método',
        405,
        {'error': 'method'},
        _failure(BookingFailureKind.invalid),
      ),
      (
        'cuerpo de más de 8 KB',
        413,
        {'error': 'tooLarge'},
        _failure(BookingFailureKind.invalid),
      ),
      (
        'cuerpo que no es JSON (415)',
        415,
        {'error': 'contentType'},
        _failure(BookingFailureKind.invalid),
      ),
      // Demasiados pedidos (la plataforma): se puede reintentar.
      (
        'demasiados pedidos',
        429,
        {'message': 'Too many requests'},
        _failure(BookingFailureKind.unavailable),
      ),
      (
        'la base no responde',
        503,
        {'error': 'unavailable'},
        _failure(BookingFailureKind.unavailable),
      ),
      (
        'error del servidor',
        500,
        {'error': 'server'},
        _failure(BookingFailureKind.unavailable),
      ),
      (
        'respuesta que no es JSON (502)',
        502,
        'Bad Gateway',
        _failure(BookingFailureKind.unavailable),
      ),
    ];

    for (final (name, status, body, matcher) in cases) {
      test(name, () async {
        server.handler = (_) async => body is String
            ? http.Response(
                body,
                status,
                headers: {'content-type': 'text/plain'},
              )
            : jsonResponse(body, status: status);
        await expectLater(repository.createBooking(confirmation()), matcher);
      });
    }

    test('sin conexión', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.createBooking(confirmation()),
        _failure(BookingFailureKind.unavailable),
      );
    });

    test('una respuesta 201 con otra forma', () async {
      server.handler = (_) async => jsonResponse({'ok': true}, status: 201);
      await expectLater(
        repository.createBooking(confirmation()),
        _failure(BookingFailureKind.unavailable),
      );
    });

    test('una semana con un dato de otro tipo (sessionId numérico)', () async {
      final body = {
        ...created(),
        'weeks': [
          for (final week in created()['weeks']! as List<Object?>)
            {...week! as Map<String, Object?>, 'sessionId': 7},
        ],
      };
      server.handler = (_) async => jsonResponse(body, status: 201);
      await expectLater(
        repository.createBooking(confirmation()),
        _failure(BookingFailureKind.unavailable),
      );
    });
  });

  test('BookingFailure no imprime la fecha ni el detalle, solo el tipo', () {
    final failure = BookingFailure(BookingFailureKind.slotTaken, date: monday);
    expect(failure.toString(), 'BookingFailure(slotTaken)');
  });
}

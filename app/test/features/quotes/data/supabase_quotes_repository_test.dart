// El presupuesto con el SDK real contra un servidor HTTP simulado: el último
// del pedido, leído de quotes con la RLS de la cocina en una sola consulta
// (sus semanas y, de sus envíos, solo el último que salió), y prepararlo,
// cambiarle el precio y retirarlo con la función chef (POST con la sesión de
// Evelyn y la región en la URL, nunca la cabecera x-region): la respuesta
// leída entera o nada y cada error a su tipo.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/quotes/domain/quote_api.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';

import '../../../support/quote_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

Matcher _quoteFailure(QuoteFailureKind kind) =>
    throwsA(isA<QuoteFailure>().having((f) => f.kind, 'kind', kind));

Matcher _bookingFailure(
  BookingFailureKind kind, {
  CalendarDate? date,
  String? requestStatus,
}) => throwsA(
  isA<BookingFailure>()
      .having((f) => f.kind, 'kind', kind)
      .having((f) => f.date, 'date', date)
      .having((f) => f.requestStatus, 'requestStatus', requestStatus),
);

void main() {
  late FakeSupabaseHttp server;
  late SupabaseQuotesRepository repository;

  setUp(() async {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseQuotesRepository(server.client);
    await signInFake(server);
  });

  tearDown(() => server.dispose());

  final monday = CalendarDate(2026, 11, 30);
  final createRequest = CreateQuoteRequest(
    requestId: 'req-1',
    dates: [monday, monday.addDays(7)],
    start: const ClockTime.hm(10, 0),
    cookMinutes: 180,
    portions: 20,
    serviceTotalCents: 28000,
  );

  Map<String, Object?> createdBody() => {
    'dryRun': false,
    'quoteId': testQuoteId,
    'requestId': 'req-1',
    'clientId': testClientId,
    'holdUntil': '2026-11-24T09:00:00+00:00',
    'weeks': [
      for (final (i, date) in ['2026-11-30', '2026-12-07'].indexed)
        {
          'date': date,
          'start': '10:00',
          'cookMinutes': 180,
          'status': 'free',
          'suggestedStart': null,
          'serviceCents': 14000,
          'sessionId': quoteSessionId(i + 1),
        },
    ],
  };

  group('fetchLatestQuote', () {
    test('una sola lectura de quotes: el último del pedido, con sus semanas y su último envío', () async {
      server.handler = (_) async => jsonResponse([quoteRow()]);

      final quote = await repository.fetchLatestQuote(
        chefId: testChefId,
        requestId: 'req-1',
      );

      expect(quote!.id, testQuoteId);
      expect(quote.sessions, hasLength(4));
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/rest/v1/quotes');
      final query = request.url.queryParameters;
      expect(
        query['select'],
        requestQuoteColumns.replaceAll(RegExp(r'\s'), ''),
      );
      expect(query['chef_id'], 'eq.$testChefId');
      expect(query['request_id'], 'eq.req-1');
      expect(query['order'], 'created_at.desc.nullslast');
      expect(query['limit'], '1');
      // De los envíos, solo el último que salió (el orden de la base).
      expect(query['sends.sent_at'], 'not.is.null');
      expect(query['sends.order'], 'sent_at.desc.nullslast,id.desc.nullslast');
      expect(query['sends.limit'], '1');
      // La sesión de quien entró: la RLS de la cocina.
      expect(request.headers['Authorization'], 'Bearer ${fakeJwt('user-1')}');
    });

    test('las semanas por la FK de sessions (quotes también apunta a sessions) y los envíos por menu_sends_quote_fk', () {
      expect(
        requestQuoteColumns,
        contains('weeks:sessions!sessions_quote_id_chef_id_fkey('),
      );
      expect(
        requestQuoteColumns,
        contains('sends:menu_sends!menu_sends_quote_fk('),
      );
      expect(requestQuoteColumns, contains('quote_terms'));
      expect(requestQuoteColumns, isNot(contains('pricing_snapshot')));
    });

    test('null si el pedido nunca tuvo', () async {
      expect(
        await repository.fetchLatestQuote(
          chefId: testChefId,
          requestId: 'req-1',
        ),
        isNull,
      );
    });

    test('una fila rota o un 500 dan unavailable (sin el detalle)', () async {
      server.handler = (_) async => jsonResponse([
        {...quoteRow(), 'version': null},
      ]);
      await expectLater(
        repository.fetchLatestQuote(chefId: testChefId, requestId: 'req-1'),
        _quoteFailure(QuoteFailureKind.unavailable),
      );
      server.handler = (_) async => jsonResponse({
        'code': 'XX000',
        'message': 'error',
        'details': null,
        'hint': null,
      }, status: 500);
      await expectLater(
        repository.fetchLatestQuote(chefId: testChefId, requestId: 'req-1'),
        _quoteFailure(QuoteFailureKind.unavailable),
      );
    });
  });

  group('createQuote', () {
    test('POST a /functions/v1/chef/quotes con la sesión, la región en la URL y las claves del contrato', () async {
      server.handler = (_) async => jsonResponse(createdBody(), status: 201);

      final draft = await repository.createQuote(createRequest);

      expect(draft.quoteId, testQuoteId);
      expect(draft.firstSessionId, quoteSessionId(1));
      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/functions/v1/chef/quotes');
      expect(request.url.queryParameters, {
        'forceFunctionRegion': 'eu-central-1',
      });
      expect(request.headers['Authorization'], 'Bearer ${fakeJwt('user-1')}');
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('x-region')),
      );
      expect(jsonBodyOf(request), {
        'requestId': 'req-1',
        'dates': ['2026-11-30', '2026-12-07'],
        'start': '10:00',
        'cookMinutes': 180,
        'portions': 20,
        'serviceTotalCents': 28000,
        'dryRun': false,
      });
    });

    test('el dryRun: el estado de cada fecha', () async {
      server.handler = (_) async => jsonResponse({
        'dryRun': true,
        'quoteId': null,
        'requestId': 'req-1',
        'clientId': testClientId,
        'holdUntil': null,
        'weeks': [
          {
            'date': '2026-11-30',
            'start': '09:00',
            'cookMinutes': 180,
            'status': 'blocked',
            'suggestedStart': '09:00',
            'serviceCents': 0,
            'sessionId': null,
          },
        ],
      });
      final draft = await repository.createQuote(
        createRequest.copyWith(
          dates: [monday],
          start: null,
          serviceTotalCents: null,
          dryRun: true,
        ),
      );
      expect(draft.dryRun, isTrue);
      expect(jsonBodyOf(server.last), {
        'requestId': 'req-1',
        'dates': ['2026-11-30'],
        'cookMinutes': 180,
        'portions': 20,
        'dryRun': true,
      });
    });

    test(
      'una respuesta de otro pedido o con otra forma: unavailable',
      () async {
        server.handler = (_) async =>
            jsonResponse({...createdBody(), 'requestId': 'otro'}, status: 201);
        await expectLater(
          repository.createQuote(createRequest),
          _bookingFailure(BookingFailureKind.unavailable),
        );
        server.handler = (_) async =>
            jsonResponse({...createdBody(), 'holdUntil': null}, status: 201);
        await expectLater(
          repository.createQuote(createRequest),
          _bookingFailure(BookingFailureKind.unavailable),
        );
      },
    );

    final cases =
        <(String, int, Object?, BookingFailureKind, CalendarDate?, String?)>[
          (
            'ya tiene uno abierto',
            409,
            {'error': 'quoteExists'},
            BookingFailureKind.quoteExists,
            null,
            null,
          ),
          (
            'un pedido de cambios',
            409,
            {'error': 'requestNotQuotable'},
            BookingFailureKind.requestNotQuotable,
            null,
            null,
          ),
          (
            'el pedido ya no está nuevo',
            409,
            {'error': 'requestNotNew', 'status': 'quoted'},
            BookingFailureKind.requestNotNew,
            null,
            'quoted',
          ),
          (
            'una semana choca',
            409,
            {'error': 'slotTaken', 'date': '2026-12-07'},
            BookingFailureKind.slotTaken,
            CalendarDate(2026, 12, 7),
            null,
          ),
          (
            'esa semana ya tiene otra',
            409,
            {'error': 'weekTaken', 'date': '2026-11-30'},
            BookingFailureKind.weekTaken,
            CalendarDate(2026, 11, 30),
            null,
          ),
          (
            'otro choque',
            409,
            {'error': 'conflict'},
            BookingFailureKind.conflict,
            null,
            null,
          ),
          (
            'un campo no vale',
            400,
            {
              'errors': {'dates': 'weeksOnlyForWeek'},
            },
            BookingFailureKind.invalid,
            null,
            null,
          ),
          (
            'el pedido no es de esta cocina',
            404,
            {'error': 'requestNotFound'},
            BookingFailureKind.notFound,
            null,
            null,
          ),
          (
            'la función no está desplegada',
            404,
            {'error': 'notFound'},
            BookingFailureKind.unavailable,
            null,
            null,
          ),
          (
            'sin sesión',
            401,
            {'error': 'unauthorized'},
            BookingFailureKind.unauthorized,
            null,
            null,
          ),
          (
            'no es de la cocina',
            403,
            {'error': 'forbidden'},
            BookingFailureKind.forbidden,
            null,
            null,
          ),
          (
            'la base no responde',
            503,
            {'error': 'unavailable'},
            BookingFailureKind.unavailable,
            null,
            null,
          ),
          (
            'algo roto',
            500,
            {'error': 'server'},
            BookingFailureKind.unavailable,
            null,
            null,
          ),
        ];
    for (final (name, status, body, kind, date, requestStatus) in cases) {
      test('cada error a su tipo: $name', () async {
        server.handler = (_) async => jsonResponse(body, status: status);
        await expectLater(
          repository.createQuote(createRequest),
          _bookingFailure(kind, date: date, requestStatus: requestStatus),
        );
      });
    }

    test('sin conexión: unavailable', () async {
      server.handler = (_) async => throw http.ClientException('sin red');
      await expectLater(
        repository.createQuote(createRequest),
        _bookingFailure(BookingFailureKind.unavailable),
      );
    });
  });

  group('changePrice', () {
    test(
      'POST a /functions/v1/chef/quotes/price; devuelve los términos de ahora',
      () async {
        server.handler = (_) async => jsonResponse(quoteTermsJson());
        final terms = await repository.changePrice(
          quoteId: testQuoteId,
          serviceTotalCents: 56000,
        );
        expect(terms.totalCents, 56000);
        final request = server.last;
        expect(request.url.path, '/functions/v1/chef/quotes/price');
        expect(request.url.queryParameters, {
          'forceFunctionRegion': 'eu-central-1',
        });
        expect(jsonBodyOf(request), {
          'quoteId': testQuoteId,
          'serviceTotalCents': 56000,
        });
      },
    );

    test(
      'con otro total o de otro presupuesto: unavailable (no se entiende)',
      () async {
        server.handler = (_) async => jsonResponse(quoteTermsJson());
        await expectLater(
          repository.changePrice(quoteId: testQuoteId, serviceTotalCents: 1),
          _quoteFailure(QuoteFailureKind.unavailable),
        );
      },
    );

    final cases = <(String, int, Object?, QuoteFailureKind)>[
      ('cerrado', 409, {'error': 'quoteClosed'}, QuoteFailureKind.closed),
      ('sin semanas', 409, {'error': 'quoteEmpty'}, QuoteFailureKind.empty),
      ('otro choque', 409, {'error': 'conflict'}, QuoteFailureKind.conflict),
      ('no existe', 404, {'error': 'quoteNotFound'}, QuoteFailureKind.notFound),
      (
        'la función no está',
        404,
        {'error': 'notFound'},
        QuoteFailureKind.unavailable,
      ),
      (
        'un precio fuera de rango',
        400,
        {
          'errors': {'serviceTotalCents': 'range'},
        },
        QuoteFailureKind.invalid,
      ),
      (
        'sin sesión',
        401,
        {'error': 'unauthorized'},
        QuoteFailureKind.unauthorized,
      ),
      (
        'no es de la cocina',
        403,
        {'error': 'forbidden'},
        QuoteFailureKind.forbidden,
      ),
      (
        'la base no responde',
        503,
        {'error': 'unavailable'},
        QuoteFailureKind.unavailable,
      ),
    ];
    for (final (name, status, body, kind) in cases) {
      test('cada error a su tipo: $name', () async {
        server.handler = (_) async => jsonResponse(body, status: status);
        await expectLater(
          repository.changePrice(quoteId: testQuoteId, serviceTotalCents: 100),
          _quoteFailure(kind),
        );
      });
    }
  });

  group('withdraw', () {
    test('POST a /functions/v1/chef/quotes/withdraw; idempotente', () async {
      server.handler = (_) async => jsonResponse({
        'quoteId': testQuoteId,
        'requestId': 'req-1',
        'already': true,
        'cancelled': 0,
      });
      final withdrawn = await repository.withdraw(testQuoteId);
      expect(withdrawn.already, isTrue);
      final request = server.last;
      expect(request.url.path, '/functions/v1/chef/quotes/withdraw');
      expect(jsonBodyOf(request), {'quoteId': testQuoteId});
    });

    test('de otro presupuesto: unavailable', () async {
      server.handler = (_) async => jsonResponse({
        'quoteId': 'otro',
        'requestId': 'req-1',
        'already': false,
        'cancelled': 1,
      });
      await expectLater(
        repository.withdraw(testQuoteId),
        _quoteFailure(QuoteFailureKind.unavailable),
      );
    });

    test('cerrado (aceptado, rechazado o vencido): closed', () async {
      server.handler = (_) async =>
          jsonResponse({'error': 'quoteClosed'}, status: 409);
      await expectLater(
        repository.withdraw(testQuoteId),
        _quoteFailure(QuoteFailureKind.closed),
      );
    });
  });

  test('QuoteFailure no imprime nada más que el tipo', () {
    expect(
      '${const QuoteFailure(QuoteFailureKind.closed)}',
      'QuoteFailure(closed)',
    );
  });
}

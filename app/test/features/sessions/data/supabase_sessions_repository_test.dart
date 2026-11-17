// Sesiones con el SDK real contra un servidor HTTP simulado: la lectura con la
// RLS (GET /rest/v1/sessions con la ficha, sus restricciones y el pedido
// embebidos, filtrada por la cocinera), la dirección de la ficha (PATCH
// /rest/v1/clients, solo esa columna), y mover y cancelar con la Edge
// Function chef (POST /functions/v1/chef/sessions/move y …/cancel, con la
// sesión de Evelyn y la región en la URL), con cada error traducido a
// SessionFailure.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

Matcher _failure(
  SessionFailureKind kind, {
  CalendarDate? date,
  SessionStatus? status,
  List<String> ids = const [],
}) => throwsA(
  isA<SessionFailure>()
      .having((f) => f.kind, 'kind', kind)
      .having((f) => f.date, 'date', date)
      .having((f) => f.status, 'status', status)
      .having((f) => f.sessionIds, 'sessionIds', ids),
);

void main() {
  late FakeSupabaseHttp server;
  late SupabaseSessionsRepository repository;

  setUp(() async {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseSessionsRepository(server.client);
    await signInFake(server);
  });

  tearDown(() => server.dispose());

  /// La lista de columnas como la manda el SDK (sin espacios).
  final select = cookingSessionColumns.replaceAll(RegExp(r'\s'), '');

  group('lectura con la RLS', () {
    test('las de la cocinera desde una fecha, con todo embebido, por fecha y llegada', () async {
      server.handler = (_) async => jsonResponse([
        sessionRow(),
        sessionRow(id: sessionId(2), date: '2026-12-02'),
      ]);

      final sessions = await repository.fetchSessions(
        chefId: testChefId,
        from: CalendarDate(2026, 10, 26),
      );

      expect(sessions.map((s) => s.id), [sessionId(1), sessionId(2)]);
      expect(sessions.first.client.address, 'Via Gombito 12, 24129 Bergamo');
      final request = server.last;
      expect(request.method, 'GET');
      expect(request.url.path, '/rest/v1/sessions');
      final query = request.url.queryParameters;
      expect(query['select'], select);
      expect(query['chef_id'], 'eq.$testChefId');
      expect(query['date'], 'gte.2026-10-26');
      expect(query['order'], 'date.asc.nullslast,start_time.asc.nullslast');
      expect(query['limit'], '$sessionsPageSize');
      // Con la sesión de Evelyn: la RLS decide qué filas ve.
      expect(request.headers['Authorization'], 'Bearer ${fakeJwt('user-1')}');
      expect(request.headers['apikey'], 'sb_publishable_test');
    });

    test('una por id de la cocinera, o null si no es suya o la RLS no la deja ver', () async {
      server.handler = (_) async => jsonResponse([sessionRow()]);
      final session = await repository.fetchSession(
        chefId: testChefId,
        id: sessionId(1),
      );
      expect(session?.id, sessionId(1));
      final query = server.last.url.queryParameters;
      expect(query['select'], select);
      expect(query['id'], 'eq.${sessionId(1)}');
      // También por la cocinera: si además fuera clienta con cuenta, la RLS
      // («el cliente lee las suyas») le dejaría ver una que no es suya.
      expect(query['chef_id'], 'eq.$testChefId');

      // Sin filas (no existe, o es de otra cocinera): null.
      server.handler = (_) async => jsonResponse(<Object>[]);
      expect(
        await repository.fetchSession(chefId: testChefId, id: sessionId(9)),
        isNull,
      );
    });

    test('las de una reserva, también las canceladas', () async {
      server.handler = (_) async => jsonResponse([
        sessionRow(),
        sessionRow(id: sessionId(2), date: '2026-12-02', status: 'cancelled'),
      ]);
      final booking = await repository.fetchBookingSessions(
        chefId: testChefId,
        requestId: bookingRequestId,
      );
      expect(booking.map((s) => s.status), [
        SessionStatus.confirmed,
        SessionStatus.cancelled,
      ]);
      final query = server.last.url.queryParameters;
      expect(query['chef_id'], 'eq.$testChefId');
      expect(query['request_id'], 'eq.$bookingRequestId');
      expect(query.containsKey('status'), isFalse);
    });

    // Sin red no: el SDK reintenta los GET con esperas de segundos (PostgREST
    // 503 y errores de red); la traducción es la misma (_read).
    test('un 500, un 401 o una fila rota dan unavailable', () async {
      server.handler = (_) async =>
          jsonResponse({'message': 'boom'}, status: 500);
      await expectLater(
        repository.fetchSessions(
          chefId: testChefId,
          from: CalendarDate(2026, 11, 1),
        ),
        _failure(SessionFailureKind.unavailable),
      );

      server.handler = (_) async =>
          jsonResponse({'message': 'JWT expired'}, status: 401);
      await expectLater(
        repository.fetchSession(chefId: testChefId, id: sessionId(1)),
        _failure(SessionFailureKind.unavailable),
      );

      server.handler = (_) async => jsonResponse([
        {...sessionRow(), 'status': 'boiling'},
      ]);
      await expectLater(
        repository.fetchBookingSessions(
          chefId: testChefId,
          requestId: bookingRequestId,
        ),
        _failure(SessionFailureKind.unavailable),
      );
    });
  });

  group('dirección de la ficha', () {
    test('PATCH clients con solo la dirección, de la ficha y de la cocinera', () async {
      server.handler = (_) async => jsonResponse([
        {'id': testClientId},
      ]);

      await repository.updateClientAddress(
        chefId: testChefId,
        clientId: testClientId,
        address: 'Via Pignolo 5, Bergamo',
      );

      final request = server.last;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/clients');
      final query = request.url.queryParameters;
      expect(query['id'], 'eq.$testClientId');
      expect(query['chef_id'], 'eq.$testChefId');
      expect(query['select'], 'id');
      // Solo la dirección: el resto de la ficha no se toca.
      expect(jsonBodyOf(request), {'address': 'Via Pignolo 5, Bergamo'});
      // Con la sesión de Evelyn: la RLS decide qué ficha puede cambiar.
      expect(request.headers['Authorization'], 'Bearer ${fakeJwt('user-1')}');
    });

    test('sin filas (no existe o no es suya) da notFound; un error, unavailable', () async {
      server.handler = (_) async => jsonResponse(<Object>[]);
      await expectLater(
        repository.updateClientAddress(
          chefId: testChefId,
          clientId: testClientId,
          address: 'Via Pignolo 5, Bergamo',
        ),
        _failure(SessionFailureKind.notFound),
      );

      server.handler = (_) async => jsonResponse({
        'message': 'permission denied for table clients',
        'code': '42501',
      }, status: 403);
      await expectLater(
        repository.updateClientAddress(
          chefId: testChefId,
          clientId: testClientId,
          address: 'Via Pignolo 5, Bergamo',
        ),
        _failure(SessionFailureKind.unavailable),
      );
    });
  });

  group('mover', () {
    Map<String, Object?> moved({bool dryRun = false, bool weekTaken = false}) =>
        {
          'dryRun': dryRun,
          'sessionId': sessionId(1),
          'requestId': bookingRequestId,
          'date': '2026-12-03',
          'start': '11:00',
          'cookMinutes': 180,
          'status': 'ok',
          'suggestedStart': '10:00',
          'weekTaken': weekTaken,
        };

    test('POST a /functions/v1/chef/sessions/move con la sesión, la región en la URL y el cuerpo del contrato', () async {
      server.handler = (_) async =>
          jsonResponse(moved(dryRun: true, weekTaken: true));

      final result = await repository.moveSession(
        MoveSessionRequest(
          sessionId: sessionId(1),
          date: CalendarDate(2026, 12, 3),
          start: const ClockTime.hm(11, 0),
          dryRun: true,
        ),
      );

      expect(result.weekTaken, isTrue);
      expect(result.date, CalendarDate(2026, 12, 3));
      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/functions/v1/chef/sessions/move');
      expect(request.url.queryParameters, {
        'forceFunctionRegion': 'eu-central-1',
      });
      expect(request.headers['Authorization'], 'Bearer ${fakeJwt('user-1')}');
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('x-region')),
      );
      expect(jsonBodyOf(request), {
        'sessionId': sessionId(1),
        'date': '2026-12-03',
        'start': '11:00',
        'dryRun': true,
      });
    });

    test('un 409 slotTaken o weekTaken trae la fecha; sessionNotMovable, el estado', () async {
      final request = MoveSessionRequest(
        sessionId: sessionId(1),
        date: CalendarDate(2026, 12, 3),
      );
      server.handler = (_) async => jsonResponse({
        'error': 'slotTaken',
        'date': '2026-12-03',
      }, status: 409);
      await expectLater(
        repository.moveSession(request),
        _failure(SessionFailureKind.slotTaken, date: CalendarDate(2026, 12, 3)),
      );

      server.handler = (_) async => jsonResponse({
        'error': 'weekTaken',
        'date': '2026-12-03',
      }, status: 409);
      await expectLater(
        repository.moveSession(request),
        _failure(SessionFailureKind.weekTaken, date: CalendarDate(2026, 12, 3)),
      );

      server.handler = (_) async => jsonResponse({
        'error': 'sessionNotMovable',
        'status': 'cooked',
      }, status: 409);
      await expectLater(
        repository.moveSession(request),
        _failure(SessionFailureKind.notMovable, status: SessionStatus.cooked),
      );
    });
  });

  group('cancelar', () {
    final request = CancelSessionsRequest(
      sessionIds: [sessionId(2), sessionId(3)],
      reason: CancelReason.clientCancelled,
    );

    test(
      'POST a /functions/v1/chef/sessions/cancel con los ids y el motivo',
      () async {
        server.handler = (_) async => jsonResponse({
          'cancelled': [sessionId(2)],
          'alreadyCancelled': [sessionId(3)],
          'withPayments': <String>[],
          'hadPayments': false,
        });

        final result = await repository.cancelSessions(request);

        expect(result.allCancelled, {sessionId(2), sessionId(3)});
        final sent = server.last;
        expect(sent.method, 'POST');
        expect(sent.url.path, '/functions/v1/chef/sessions/cancel');
        expect(sent.url.queryParameters, {
          'forceFunctionRegion': 'eu-central-1',
        });
        expect(jsonBodyOf(sent), {
          'sessionIds': [sessionId(2), sessionId(3)],
          'reason': 'client_cancelled',
          'allowWithPayments': false,
        });
      },
    );

    test('un 409 hasPayments trae las semanas cobradas; invalidTransition, la sesión', () async {
      server.handler = (_) async => jsonResponse({
        'error': 'hasPayments',
        'sessionIds': [sessionId(2)],
      }, status: 409);
      await expectLater(
        repository.cancelSessions(request),
        _failure(SessionFailureKind.hasPayments, ids: [sessionId(2)]),
      );

      server.handler = (_) async => jsonResponse({
        'error': 'invalidTransition',
        'sessionId': sessionId(3),
      }, status: 409);
      await expectLater(
        repository.cancelSessions(request),
        _failure(SessionFailureKind.invalidTransition, ids: [sessionId(3)]),
      );
    });
  });

  group('cada error, a su tipo', () {
    final move = MoveSessionRequest(
      sessionId: sessionId(1),
      date: CalendarDate(2026, 12, 3),
    );
    final cases = <(String, int, Object?, Matcher)>[
      (
        'otro 409',
        409,
        {'error': 'conflict'},
        _failure(SessionFailureKind.conflict),
      ),
      (
        'slotTaken sin una fecha válida',
        409,
        {'error': 'slotTaken', 'date': 'mañana'},
        _failure(SessionFailureKind.conflict),
      ),
      (
        'sessionNotMovable con un estado desconocido',
        409,
        {'error': 'sessionNotMovable', 'status': 'boiling'},
        _failure(SessionFailureKind.notMovable),
      ),
      (
        'validación por campo',
        400,
        {
          'errors': {'date': 'dateOutOfRange'},
        },
        _failure(SessionFailureKind.invalid),
      ),
      (
        'sin sesión válida',
        401,
        {'error': 'unauthorized'},
        _failure(SessionFailureKind.unauthorized),
      ),
      (
        'no es la cocinera',
        403,
        {'error': 'forbidden'},
        _failure(SessionFailureKind.forbidden),
      ),
      (
        'la sesión no existe',
        404,
        {'error': 'sessionNotFound'},
        _failure(SessionFailureKind.notFound),
      ),
      // La función no está desplegada: la plataforma responde 404 con su cuerpo.
      (
        'función inexistente',
        404,
        {'message': 'Not found'},
        _failure(SessionFailureKind.unavailable),
      ),
      (
        'otro método',
        405,
        {'error': 'method'},
        _failure(SessionFailureKind.invalid),
      ),
      (
        'cuerpo de más de 8 KB',
        413,
        {'error': 'tooLarge'},
        _failure(SessionFailureKind.invalid),
      ),
      (
        'cuerpo que no es JSON',
        415,
        {'error': 'contentType'},
        _failure(SessionFailureKind.invalid),
      ),
      (
        'demasiados pedidos',
        429,
        {'message': 'Too many requests'},
        _failure(SessionFailureKind.unavailable),
      ),
      (
        'la base no responde',
        503,
        {'error': 'unavailable'},
        _failure(SessionFailureKind.unavailable),
      ),
      (
        'error del servidor',
        500,
        {'error': 'server'},
        _failure(SessionFailureKind.unavailable),
      ),
      (
        'respuesta que no es JSON',
        502,
        'Bad Gateway',
        _failure(SessionFailureKind.unavailable),
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
        await expectLater(repository.moveSession(move), matcher);
      });
    }

    test('sin conexión', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.moveSession(move),
        _failure(SessionFailureKind.unavailable),
      );
    });

    test('una respuesta 200 con otra forma', () async {
      server.handler = (_) async => jsonResponse({'ok': true});
      await expectLater(
        repository.moveSession(move),
        _failure(SessionFailureKind.unavailable),
      );
      await expectLater(
        repository.cancelSessions(
          CancelSessionsRequest(sessionIds: [sessionId(1)]),
        ),
        _failure(SessionFailureKind.unavailable),
      );
    });
  });

  test('SessionFailure no imprime la fecha ni los ids, solo el tipo', () {
    final failure = SessionFailure(
      SessionFailureKind.hasPayments,
      date: CalendarDate(2026, 12, 3),
      sessionIds: [sessionId(2)],
    );
    expect(failure.toString(), 'SessionFailure(hasPayments)');
  });
}

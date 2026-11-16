// Consultas reales del SDK de Supabase contra un servidor HTTP simulado:
// columnas, filtros y orden de la lectura, el upsert que nunca pisa un
// bloqueo que ya existía, el borrado por ids, la nota y los errores.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/availability/domain/availability.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

Matcher _failure(AvailabilityFailureKind kind) => throwsA(
  isA<AvailabilityFailure>().having((f) => f.kind, 'kind', kind),
);

void main() {
  late FakeSupabaseHttp server;
  late SupabaseAvailabilityRepository repository;

  final friday = CalendarDate(2026, 10, 23);
  final saturday = CalendarDate(2026, 10, 24);

  setUp(() {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseAvailabilityRepository(server.client);
  });

  tearDown(() => server.dispose());

  group('fetch', () {
    test('lee el horario y los bloqueos de la cocinera, con filtros y orden', () async {
      server.handler = (request) async => switch (request.url.path) {
        '/rest/v1/availability_rules' => jsonResponse([
          {'dow': 1, 'start_time': '09:00:00', 'end_time': '15:00:00'},
          {'dow': 5, 'start_time': '09:00:00', 'end_time': '13:30:00'},
        ]),
        '/rest/v1/availability_exceptions' => jsonResponse([
          {'id': 'b1', 'date': '2026-10-23', 'note': 'Ferie'},
        ]),
        _ => jsonResponse({'message': 'not found'}, status: 404),
      };

      final snapshot = await repository.fetch(
        chefId: testChefId,
        from: CalendarDate(2026, 9, 28),
      );

      // "09:00:00" se lee como 9 h.
      expect(snapshot.rules, const [
        AvailabilityRule(weekday: 1, start: Duration(hours: 9), end: Duration(hours: 15)),
        AvailabilityRule(
          weekday: 5,
          start: Duration(hours: 9),
          end: Duration(hours: 13, minutes: 30),
        ),
      ]);
      expect(snapshot.blocked, {
        friday: BlockedDay(id: 'b1', date: friday, note: 'Ferie'),
      });

      final rules = server.requests.singleWhere(
        (r) => r.url.path == '/rest/v1/availability_rules',
      );
      expect(rules.method, 'GET');
      expect(rules.url.queryParameters['select'], 'dow,start_time,end_time');
      expect(rules.url.queryParameters['chef_id'], 'eq.$testChefId');
      expect(
        rules.url.queryParameters['order'],
        'dow.asc.nullslast,start_time.asc.nullslast',
      );

      final blocked = server.requests.singleWhere(
        (r) => r.url.path == '/rest/v1/availability_exceptions',
      );
      expect(blocked.method, 'GET');
      final query = blocked.url.queryParameters;
      expect(query['select'], 'id,date,note');
      expect(query['chef_id'], 'eq.$testChefId');
      expect(query['kind'], 'eq.blocked');
      expect(query['date'], 'gte.2026-09-28');
      expect(query['order'], 'date.asc.nullslast');
      // La clave publicable va en las cabeceras; nunca una secreta.
      expect(blocked.headers['apikey'], 'sb_publishable_test');
    });

    test('un 500 da AvailabilityFailure.unavailable', () async {
      server.handler = (_) async => jsonResponse(
        {'message': 'boom', 'code': 'XX000'},
        status: 500,
      );
      await expectLater(
        repository.fetch(chefId: testChefId, from: friday),
        _failure(AvailabilityFailureKind.unavailable),
      );
    });

    test('una fila rota también da unavailable', () async {
      server.handler = (request) async =>
          request.url.path == '/rest/v1/availability_rules'
          ? jsonResponse([
              {'dow': 9, 'start_time': '09:00:00', 'end_time': '15:00:00'},
            ])
          : jsonResponse(<Object>[]);
      await expectLater(
        repository.fetch(chefId: testChefId, from: friday),
        _failure(AvailabilityFailureKind.unavailable),
      );
    });
  });

  group('block', () {
    test('POST con on_conflict e ignore-duplicates: devuelve solo los bloqueos creados', () async {
      // Otro dispositivo ya había bloqueado el sábado: el servidor no lo devuelve.
      server.handler = (_) async => jsonResponse([
        {'id': 'n1', 'date': '2026-10-23', 'note': 'Ferie'},
      ], status: 201);

      final created = await repository.block(
        chefId: testChefId,
        days: [(date: friday, note: 'Ferie'), (date: saturday, note: 'Ferie')],
      );

      expect(created, [BlockedDay(id: 'n1', date: friday, note: 'Ferie')]);
      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/availability_exceptions');
      expect(request.url.queryParameters['on_conflict'], 'chef_id,date,kind');
      expect(request.url.queryParameters['select'], 'id,date,note');
      final prefer = request.headers['Prefer']!.split(',');
      expect(prefer, contains('resolution=ignore-duplicates'));
      expect(prefer, contains('return=representation'));
      expect(jsonDecode(request.body), [
        {'chef_id': testChefId, 'date': '2026-10-23', 'kind': 'blocked', 'note': 'Ferie'},
        {'chef_id': testChefId, 'date': '2026-10-24', 'kind': 'blocked', 'note': 'Ferie'},
      ]);
    });

    test('cada día lleva su nota, o null', () async {
      await repository.block(
        chefId: testChefId,
        days: [(date: friday, note: 'Ferie'), (date: saturday, note: null)],
      );
      expect(jsonDecode(server.last.body), [
        {'chef_id': testChefId, 'date': '2026-10-23', 'kind': 'blocked', 'note': 'Ferie'},
        {'chef_id': testChefId, 'date': '2026-10-24', 'kind': 'blocked', 'note': null},
      ]);
    });

    test('sin días no llama al servidor', () async {
      expect(await repository.block(chefId: testChefId, days: const []), isEmpty);
      expect(server.requests, isEmpty);
    });

    test('sin conexión da unavailable', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.block(chefId: testChefId, days: [(date: friday, note: null)]),
        _failure(AvailabilityFailureKind.unavailable),
      );
    });
  });

  group('unblock', () {
    test('DELETE de esos ids, filtrado por la cocinera', () async {
      server.handler = (_) async => http.Response('', 204);

      await repository.unblock(chefId: testChefId, ids: ['b1', 'b2']);

      final request = server.last;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/rest/v1/availability_exceptions');
      expect(request.url.queryParameters['chef_id'], 'eq.$testChefId');
      // El SDK cita cada valor (PostgREST lo acepta así).
      expect(request.url.queryParameters['id'], 'in.("b1","b2")');
    });

    test('sin ids no llama al servidor', () async {
      await repository.unblock(chefId: testChefId, ids: const []);
      expect(server.requests, isEmpty);
    });

    // Los ids van en la URL: con un año entero, un solo DELETE pasaría de los
    // 8 KB que aceptan nginx y Kong en la línea del pedido (414).
    test('un año de ids sale en tandas de 100, cada DELETE con la URL corta', () async {
      server.handler = (_) async => http.Response('', 204);
      final ids = [
        for (var i = 0; i < 366; i++)
          '7e5b3000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
      ];

      await repository.unblock(chefId: testChefId, ids: ids);

      expect(server.requests, hasLength(4));
      final sent = [
        for (final request in server.requests)
          for (final match in RegExp(
            '"([^"]+)"',
          ).allMatches(request.url.queryParameters['id']!))
            match.group(1),
      ];
      expect(sent, ids, reason: 'todos, en orden y una sola vez');
      for (final request in server.requests) {
        expect(request.method, 'DELETE');
        expect(request.url.queryParameters['chef_id'], 'eq.$testChefId');
        expect(request.url.toString().length, lessThan(6000));
      }
    });

    test('si una tanda falla da unavailable y no manda las que siguen', () async {
      server.handler = (_) async => server.requests.length == 2
          ? jsonResponse({'message': 'URI Too Long'}, status: 414)
          : http.Response('', 204);

      await expectLater(
        repository.unblock(
          chefId: testChefId,
          ids: [for (var i = 0; i < 250; i++) 'b$i'],
        ),
        _failure(AvailabilityFailureKind.unavailable),
      );
      expect(server.requests, hasLength(2));
    });

    test('un error de permisos da unavailable', () async {
      server.handler = (_) async => jsonResponse(
        {'message': 'permission denied', 'code': '42501'},
        status: 403,
      );
      await expectLater(
        repository.unblock(chefId: testChefId, ids: ['b1']),
        _failure(AvailabilityFailureKind.unavailable),
      );
    });
  });

  group('updateNote', () {
    test('PATCH solo de la nota, de ese bloqueo y de la cocinera', () async {
      server.handler = (_) async => jsonResponse([
        {'id': 'b1'},
      ]);

      await repository.updateNote(chefId: testChefId, id: 'b1', note: 'Vacanze');

      final request = server.last;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/availability_exceptions');
      expect(request.url.queryParameters['id'], 'eq.b1');
      expect(request.url.queryParameters['chef_id'], 'eq.$testChefId');
      expect(request.url.queryParameters['select'], 'id');
      expect(jsonBodyOf(request), {'note': 'Vacanze'});
    });

    test('null borra la nota', () async {
      server.handler = (_) async => jsonResponse([
        {'id': 'b1'},
      ]);
      await repository.updateNote(chefId: testChefId, id: 'b1', note: null);
      expect(jsonBodyOf(server.last), {'note': null});
    });

    test('si el bloqueo ya no existe (lo quitó otro dispositivo) da notFound', () async {
      server.handler = (_) async => jsonResponse(<Object>[]);
      await expectLater(
        repository.updateNote(chefId: testChefId, id: 'b1', note: 'Vacanze'),
        _failure(AvailabilityFailureKind.notFound),
      );
    });

    test('sin conexión da unavailable', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.updateNote(chefId: testChefId, id: 'b1', note: 'Vacanze'),
        _failure(AvailabilityFailureKind.unavailable),
      );
    });
  });

  test('AvailabilityFailure no imprime nada más que el tipo', () {
    expect(
      const AvailabilityFailure(AvailabilityFailureKind.unavailable).toString(),
      'AvailabilityFailure(unavailable)',
    );
  });
}

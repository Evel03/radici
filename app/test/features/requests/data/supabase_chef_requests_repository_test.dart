// Consultas reales del SDK de Supabase contra un servidor HTTP simulado:
// columnas, filtros, orden y manejo de errores.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/chosen_menu.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

/// Espera (con tiempo real) a que se cumpla [condition].
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('No se cumplió la condición a tiempo');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late FakeSupabaseHttp server;
  late SupabaseChefRequestsRepository repository;

  setUp(() {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseChefRequestsRepository(
      server.client,
      clock: () => DateTime.utc(2026, 10, 19, 12, 30),
    );
  });

  tearDown(() => server.dispose());

  group('fetchRequests', () {
    test('lee las columnas del contrato con el cliente embebido', () async {
      server.handler = (_) async => jsonResponse([
        requestRow(id: 'b', createdAt: '2026-10-19T10:00:00+00:00'),
        requestRow(id: 'a', createdAt: '2026-10-18T10:00:00+00:00'),
      ]);

      final requests = await repository.fetchRequests(chefId: testChefId);

      expect(requests.map((r) => r.id), ['b', 'a']);
      expect(requests.first.client.displayName, 'Giulia Rossi');

      final request = server.last;
      expect(request.method, 'GET');
      expect(request.url.path, '/rest/v1/requests');
      final query = request.url.queryParameters;
      expect(
        query['select'],
        // weeks: requests.weeks (20261116120000_weekly_pricing.sql).
        // wishes: los platos elegidos en la web (20261119150000_menu_web.sql).
        'id,chef_id,client_id,type,status,adults,kids,days,meals,weeks,'
        'restrictions,no_allergies,notes,wishes,preferred_date,preferred_slot,locale,'
        'whatsapp_opt_in,estimate,source,seen_at,created_at,contact,'
        'client:clients(display_name,contact_email,contact_phone,zone,status)',
      );
      expect(query['chef_id'], 'eq.$testChefId');
      expect(query['order'], startsWith('created_at.desc'));
      expect(query['limit'], '$requestsPageSize');
      // La clave publicable va en las cabeceras; nunca una service role.
      expect(request.headers['apikey'], 'sb_publishable_test');
    });

    test('error del servidor → RequestsFailure.unavailable', () async {
      server.handler = (_) async => jsonResponse(
        {'message': 'boom', 'code': 'XX000'},
        status: 500,
      );
      await expectLater(
        repository.fetchRequests(chefId: testChefId),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.unavailable,
          ),
        ),
      );
    });

    test('sin conexión → RequestsFailure.unavailable', () async {
      // Se prueba con un PATCH: los GET los reintenta el SDK (3 veces, con
      // espera) antes de fallar, y el test tardaría segundos.
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.reject('req-1'),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.unavailable,
          ),
        ),
      );
    });
  });

  group('fetchRequest', () {
    test('por id; null si no existe', () async {
      server.handler = (_) async => jsonResponse([requestRow(id: 'x')]);
      final found = await repository.fetchRequest('x');
      expect(found?.id, 'x');
      expect(server.last.url.queryParameters['id'], 'eq.x');

      server.handler = (_) async => jsonResponse(<Object>[]);
      expect(await repository.fetchRequest('missing'), isNull);
    });
  });

  // requests.wishes es un uuid[] sin FK: no se puede embeber, se piden los
  // platos por id (la RLS deja leer a la cocinera todos los suyos).
  group('fetchMenuDishes', () {
    const lasagneId = 'a0000000-0000-4000-8000-000000000001';
    const minestroneId = 'a0000000-0000-4000-8000-000000000003';

    test('GET de recipes con solo los nombres, filtrado por los ids', () async {
      server.handler = (_) async => jsonResponse([
        {'id': minestroneId, 'name_it': 'Minestrone di verdure', 'name_es': null, 'name_en': null},
        {
          'id': lasagneId,
          'name_it': 'Lasagne alla bolognese',
          'name_es': 'Lasaña a la boloñesa',
          'name_en': 'Lasagne Bolognese',
        },
      ]);

      final dishes = await repository.fetchMenuDishes(const [lasagneId, minestroneId]);

      expect(dishes, const [
        MenuDish(id: minestroneId, nameIt: 'Minestrone di verdure'),
        MenuDish(
          id: lasagneId,
          nameIt: 'Lasagne alla bolognese',
          nameEs: 'Lasaña a la boloñesa',
          nameEn: 'Lasagne Bolognese',
        ),
      ]);
      final request = server.last;
      expect(request.method, 'GET');
      expect(request.url.path, '/rest/v1/recipes');
      final query = request.url.queryParameters;
      // Nunca ingredientes, alérgenos ni notas: solo para mostrar los nombres.
      expect(query['select'], 'id,name_it,name_es,name_en');
      expect(query['id'], 'in.("$lasagneId","$minestroneId")');
      expect(query.keys.toSet(), {'select', 'id'});
    });

    test('sin ids no consulta nada', () async {
      expect(await repository.fetchMenuDishes(const []), isEmpty);
      expect(server.requests, isEmpty);
    });

    test('error del servidor o fila rota → RequestsFailure.unavailable', () async {
      final unavailable = throwsA(
        isA<RequestsFailure>().having((f) => f.kind, 'kind', RequestsFailureKind.unavailable),
      );
      server.handler = (_) async => jsonResponse({'message': 'boom', 'code': 'XX000'}, status: 500);
      await expectLater(repository.fetchMenuDishes(const [lasagneId]), unavailable);

      server.handler = (_) async => jsonResponse([
        {'id': lasagneId, 'name_it': null},
      ]);
      await expectLater(repository.fetchMenuDishes(const [lasagneId]), unavailable);
    });
  });

  group('markSeen', () {
    test('PATCH seen_at solo si todavía era null y devuelve lo guardado', () async {
      server.handler = (_) async =>
          jsonResponse([{'seen_at': '2026-10-19T12:30:00.123+00:00'}]);

      final seenAt = await repository.markSeen('req-1');

      expect(seenAt, DateTime.utc(2026, 10, 19, 12, 30, 0, 123));
      final request = server.last;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/requests');
      expect(request.url.queryParameters['id'], 'eq.req-1');
      expect(request.url.queryParameters['seen_at'], 'is.null');
      expect(request.url.queryParameters['select'], 'seen_at');
      expect(jsonBodyOf(request), {'seen_at': '2026-10-19T12:30:00.000Z'});
      // Solo cambia seen_at: nada de estado ni datos del cliente.
      expect(jsonBodyOf(request).keys, ['seen_at']);
    });

    test('si ya estaba visto, devuelve el valor anterior', () async {
      server.handler = (request) async => request.method == 'PATCH'
          ? jsonResponse(<Object>[])
          : jsonResponse([{'seen_at': '2026-10-18T08:00:00+00:00'}]);

      expect(await repository.markSeen('req-1'), DateTime.utc(2026, 10, 18, 8));
      expect(server.requests.map((r) => r.method), ['PATCH', 'GET']);
    });

    test('pedido inexistente → notFound', () async {
      server.handler = (_) async => jsonResponse(<Object>[]);
      await expectLater(
        repository.markSeen('missing'),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.notFound,
          ),
        ),
      );
    });
  });

  group('reject', () {
    test('PATCH status=rejected solo desde new', () async {
      server.handler = (_) async => jsonResponse([{'id': 'req-1'}]);

      await repository.reject('req-1');

      final request = server.last;
      expect(request.method, 'PATCH');
      expect(request.url.queryParameters['id'], 'eq.req-1');
      expect(request.url.queryParameters['status'], 'eq.new');
      expect(jsonBodyOf(request), {'status': 'rejected'});
    });

    test('si ya no estaba en new → conflict', () async {
      server.handler = (_) async => jsonResponse(<Object>[]);
      await expectLater(
        repository.reject('req-1'),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.conflict,
          ),
        ),
      );
    });

    test('error de permisos (RLS) → unavailable', () async {
      server.handler = (_) async => jsonResponse(
        {'message': 'permission denied', 'code': '42501'},
        status: 403,
      );
      await expectLater(
        repository.reject('req-1'),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.unavailable,
          ),
        ),
      );
    });
  });

  group('undoReject', () {
    test('PATCH status=new solo desde rejected', () async {
      server.handler = (_) async => jsonResponse([{'id': 'req-1'}]);

      await repository.undoReject('req-1');

      final request = server.last;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/requests');
      expect(request.url.queryParameters['id'], 'eq.req-1');
      expect(request.url.queryParameters['status'], 'eq.rejected');
      expect(request.url.queryParameters['select'], 'id');
      // Solo el estado: "visto" y los datos del pedido no se tocan.
      expect(jsonBodyOf(request), {'status': 'new'});
    });

    test('si ya no estaba rechazado → conflict', () async {
      server.handler = (_) async => jsonResponse(<Object>[]);
      await expectLater(
        repository.undoReject('req-1'),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.conflict,
          ),
        ),
      );
    });

    test('la base no lo permite (42501) → unavailable', () async {
      server.handler = (_) async => jsonResponse(
        {'message': 'request_status_change_not_allowed', 'code': '42501'},
        status: 403,
      );
      await expectLater(
        repository.undoReject('req-1'),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.unavailable,
          ),
        ),
      );
    });
  });

  group('markClientAsCustomer', () {
    test('PATCH clients status=trial solo si la ficha todavía es un prospecto', () async {
      server.handler = (_) async => jsonResponse([{'id': testClientId}]);

      await repository.markClientAsCustomer(testClientId);

      final request = server.last;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/clients');
      expect(request.url.queryParameters['id'], 'eq.$testClientId');
      expect(request.url.queryParameters['status'], 'eq.prospect');
      expect(request.url.queryParameters['select'], 'id');
      // Solo el estado: la ficha no se toca.
      expect(jsonBodyOf(request), {'status': 'trial'});
    });

    test('si ya no era un prospecto (o no existe) → conflict', () async {
      server.handler = (_) async => jsonResponse(<Object>[]);
      await expectLater(
        repository.markClientAsCustomer(testClientId),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.conflict,
          ),
        ),
      );
    });

    test('error de permisos o del servidor → unavailable', () async {
      server.handler = (_) async => jsonResponse(
        {'message': 'only_chef_can_change_client_status', 'code': '42501'},
        status: 403,
      );
      await expectLater(
        repository.markClientAsCustomer(testClientId),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.unavailable,
          ),
        ),
      );
    });
  });

  group('Realtime', () {
    test('estados del canal → conectado o desconectado', () {
      expect(
        realtimeEventOf(RealtimeSubscribeStatus.subscribed),
        isA<RealtimeConnected>(),
      );
      for (final status in [
        RealtimeSubscribeStatus.channelError,
        RealtimeSubscribeStatus.closed,
        RealtimeSubscribeStatus.timedOut,
      ]) {
        expect(realtimeEventOf(status), isA<RealtimeDisconnected>());
      }
    });

    test('el id del pedido sale del registro nuevo', () {
      expect(insertedRequestIdOf({'id': 'abc', 'chef_id': testChefId}), 'abc');
      expect(insertedRequestIdOf({'id': ''}), isNull);
      expect(insertedRequestIdOf({'id': 42}), isNull);
      expect(insertedRequestIdOf({}), isNull);
    });

    test('suscribe INSERT en public.requests filtrado por chef_id, avisa los '
        'pedidos nuevos y vuelve a avisar "conectado" al reconectar', () async {
      final events = <RequestsRealtimeEvent>[];
      final joined = server.realtime.onJoin.first;
      final subscription = repository
          .watchNewRequests(chefId: testChefId)
          .listen(events.add);

      final topic = await joined.timeout(const Duration(seconds: 5));
      expect(topic, startsWith('realtime:chef-requests-$testChefId'));
      expect(server.realtime.joins.single.postgresChanges.single, {
        'event': 'INSERT',
        'schema': 'public',
        'table': 'requests',
        'filter': 'chef_id=eq.$testChefId',
      });
      await _until(() => events.isNotEmpty);
      expect(events.single, isA<RealtimeConnected>());

      // Llega un pedido.
      server.realtime.pushInsert(topic, {'id': 'req-9', 'chef_id': testChefId});
      await _until(() => events.length == 2);
      expect(events[1], isA<RequestInserted>());
      expect((events[1] as RequestInserted).requestId, 'req-9');

      // Se corta la conexión: avisa y, al reconectar solo, se vuelve a unir.
      final rejoined = server.realtime.onJoin.first;
      await server.realtime.dropConnection();
      await _until(() => events.whereType<RealtimeDisconnected>().isNotEmpty);
      await rejoined.timeout(const Duration(seconds: 15));
      await _until(() => events.last is RealtimeConnected);
      expect(server.realtime.connections, 2);

      // Al cancelar se cierra el canal.
      await subscription.cancel();
      expect(server.client.getChannels(), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  test('la fila de ejemplo es un pedido válido', () {
    expect(ChefRequest.fromJson(requestRow()).status, RequestStatus.newRequest);
  });
}

// Directorio de fichas con el SDK real contra un servidor HTTP simulado: la
// consulta (con la RLS de la cocinera, sin dirección, email ni restricciones),
// el último pedido semanal embebido, el orden y cada error como
// ClientsFailure, sin loguear nada.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/features/clients/data/clients_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/client_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

void main() {
  late FakeSupabaseHttp server;
  late SupabaseClientsRepository repository;

  setUp(() {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseClientsRepository(server.client);
  });

  tearDown(() => server.dispose());

  test('GET /rest/v1/clients con el último pedido semanal embebido, sin datos de más', () async {
    server.handler = (_) async => jsonResponse([
      clientRow(requests: [latestRequestRow()]),
      clientRow(id: 'c-2', name: 'Anna Verdi', status: 'prospect'),
    ]);

    final clients = await repository.fetchClients(chefId: testChefId);

    expect(clients.map((c) => c.id), [testClientId, 'c-2']);
    expect(clients.first.latestWeekly?.locale, ClientLocale.es);
    expect(clients.last.status, ClientStatus.prospect);

    final request = server.last;
    expect(request.method, 'GET');
    expect(request.url.path, '/rest/v1/clients');
    final query = request.url.queryParameters;
    expect(
      query['select'],
      'id,display_name,contact_phone,zone,adults,kids,status,'
      'requests(type,locale,adults,kids,days,meals,created_at)',
    );
    // Lo mínimo: ni la dirección, ni el email, ni las restricciones, ni las
    // notas, ni el contacto del pedido.
    for (final column in [
      'address',
      'contact_email',
      'restrictions',
      'notes',
      'contact',
      'preferences',
      'kitchen_notes',
    ]) {
      expect(query['select'], isNot(contains('$column,')), reason: column);
      expect(query['select'], isNot(endsWith(column)), reason: column);
    }
    expect(query['chef_id'], 'eq.$testChefId');
    // Solo los pedidos semanales, el más reciente.
    expect(query['requests.type'], 'eq.week');
    expect(query['requests.order'], startsWith('created_at.desc'));
    expect(query['requests.limit'], '1');
    // display_name.asc: con más de 1000 fichas, el límite corta las últimas
    // por nombre, no las primeras.
    expect(query['order'], startsWith('display_name.asc'));
    expect(query['limit'], '1000');
  });

  Matcher unavailable() => throwsA(
    isA<ClientsFailure>().having(
      (f) => f.kind,
      'kind',
      ClientsFailureKind.unavailable,
    ),
  );

  test('un 500 o una fila sin nombre: ClientsFailure.unavailable', () async {
    server.handler = (_) async =>
        jsonResponse({'message': 'boom'}, status: 500);
    await expectLater(repository.fetchClients(chefId: testChefId), unavailable());

    server.handler = (_) async => jsonResponse([clientRow(name: null)]);
    await expectLater(repository.fetchClients(chefId: testChefId), unavailable());
  });

  test('sin conexión: ClientsFailure.unavailable (después de los reintentos del SDK)', () async {
    server.handler = (_) async => throw http.ClientException('sin red');
    await expectLater(repository.fetchClients(chefId: testChefId), unavailable());
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('ClientsFailure no lleva más que el tipo', () {
    expect(
      const ClientsFailure(ClientsFailureKind.unavailable).toString(),
      'ClientsFailure(unavailable)',
    );
  });
}

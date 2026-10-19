// Rol y ficha de la cocinera, contra PostgREST simulado.
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/features/auth/data/account_repository.dart';
import 'package:mestolo/features/auth/domain/auth_models.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

void main() {
  late FakeSupabaseHttp server;
  late SupabaseAccountRepository repository;

  setUp(() {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseAccountRepository(server.client);
  });

  tearDown(() => server.dispose());

  test('cocinera: lee el rol y su ficha en chefs', () async {
    server.handler = (request) async => switch (request.url.path) {
      '/rest/v1/profiles' => jsonResponse([
        {'role': 'chef'},
      ]),
      '/rest/v1/chefs' => jsonResponse([
        {'id': testChefId, 'display_name': 'Evelyn'},
      ]),
      _ => jsonResponse(<Object>[]),
    };

    final account = await repository.fetchAccount('user-1');

    expect(account, chefAccountData);
    final profiles = server.requests.first.url;
    expect(profiles.path, '/rest/v1/profiles');
    expect(profiles.queryParameters['select'], 'role');
    expect(profiles.queryParameters['id'], 'eq.user-1');
    final chefs = server.requests.last.url;
    expect(chefs.path, '/rest/v1/chefs');
    expect(chefs.queryParameters['select'], 'id,display_name');
    expect(chefs.queryParameters['profile_id'], 'eq.user-1');
  });

  test('cliente (o perfil sin rol): no consulta chefs', () async {
    server.handler = (_) async => jsonResponse([
      {'role': 'client'},
    ]);
    expect(
      await repository.fetchAccount('user-2'),
      const Account(role: AccountRole.client),
    );
    expect(server.requests, hasLength(1));

    server.handler = (_) async => jsonResponse(<Object>[]);
    expect(
      (await repository.fetchAccount('user-3')).role,
      AccountRole.client,
    );
  });

  test('rol chef sin ficha en chefs → chefNotConfigured', () async {
    server.handler = (request) async => request.url.path == '/rest/v1/profiles'
        ? jsonResponse([
            {'role': 'chef'},
          ])
        : jsonResponse(<Object>[]);
    await expectLater(
      repository.fetchAccount('user-1'),
      throwsA(
        isA<AccountFailure>().having(
          (f) => f.kind,
          'kind',
          AccountFailureKind.chefNotConfigured,
        ),
      ),
    );
  });

  test('error del servidor → unavailable', () async {
    server.handler = (_) async =>
        jsonResponse({'message': 'boom', 'code': 'XX000'}, status: 500);
    await expectLater(
      repository.fetchAccount('user-1'),
      throwsA(
        isA<AccountFailure>().having(
          (f) => f.kind,
          'kind',
          AccountFailureKind.unavailable,
        ),
      ),
    );
  });
}

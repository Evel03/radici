// Rol, idioma y ficha de la cocinera, contra PostgREST y Auth simulados.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

final Map<String, Object?> _user = fakeUserJson('user-1', 'evelyn@example.test');

/// Con sesión: Auth exige un token para actualizar la metadata.
Future<void> _signIn(FakeSupabaseHttp server) => signInFake(server);

void main() {
  late FakeSupabaseHttp server;
  late SupabaseAccountRepository repository;

  setUp(() {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseAccountRepository(server.client);
  });

  tearDown(() => server.dispose());

  /// PostgREST con un perfil chef, la cocina que da `current_chef_id()` y la
  /// ficha de esa cocina, cuya dueña es [ownerId].
  void chefSide({required String ownerId, Object? currentChefId = testChefId}) {
    server.handler = (request) async => switch (request.url.path) {
      '/rest/v1/profiles' => jsonResponse([
        {'role': 'chef', 'locale': 'es'},
      ]),
      '/rest/v1/rpc/current_chef_id' => jsonResponse(currentChefId),
      '/rest/v1/chefs' => jsonResponse([
        {'id': testChefId, 'display_name': 'Evelyn', 'profile_id': ownerId},
      ]),
      _ => jsonResponse(<Object>[]),
    };
  }

  test('cocinera: lee el rol, el idioma y la ficha de su cocina', () async {
    chefSide(ownerId: 'user-1');

    final account = await repository.fetchAccount('user-1');

    expect(account, chefAccountData.copyWith(language: AppLanguage.es));
    expect(account.chef?.collaborator, isFalse);
    final profiles = server.requests.first.url;
    expect(profiles.path, '/rest/v1/profiles');
    expect(profiles.queryParameters['select'], 'role,locale');
    expect(profiles.queryParameters['id'], 'eq.user-1');
    // La cocina la dice la base: la misma función que usan las políticas
    // (la de la que es dueña o colaborador).
    final rpc = server.requests[1];
    expect(rpc.method, 'POST');
    expect(rpc.url.path, '/rest/v1/rpc/current_chef_id');
    final chefs = server.requests.last.url;
    expect(chefs.path, '/rest/v1/chefs');
    expect(chefs.queryParameters['select'], 'id,display_name,profile_id');
    expect(chefs.queryParameters['id'], 'eq.$testChefId');
    expect(server.requests, hasLength(3));
  });

  test('colaborador: la cocina de la que es colaborador, con su ficha y '
      'marcado como colaborador', () async {
    chefSide(ownerId: 'user-1');

    final account = await repository.fetchAccount('user-socio');

    expect(
      account,
      chefAccountData.copyWith(
        chef: chefAccount.copyWith(collaborator: true),
        language: AppLanguage.es,
      ),
    );
    // Nada distinto en lo demás: el mismo chefId que ve la cocinera.
    expect(account.chef?.chefId, testChefId);
    expect(account.chef?.displayName, 'Evelyn');
  });

  test('rol chef sin cocina (ni dueña ni colaborador) → chefNotConfigured, '
      'sin leer chefs', () async {
    chefSide(ownerId: 'user-1', currentChefId: null);
    await expectLater(
      repository.fetchAccount('user-suelto'),
      throwsA(
        isA<AccountFailure>().having(
          (f) => f.kind,
          'kind',
          AccountFailureKind.chefNotConfigured,
        ),
      ),
    );
    expect(server.requests.where((r) => r.url.path == '/rest/v1/chefs'), isEmpty);
  });

  test('cliente (o perfil sin rol): no consulta chefs', () async {
    server.handler = (_) async => jsonResponse([
      {'role': 'client', 'locale': 'it'},
    ]);
    expect(
      await repository.fetchAccount('user-2'),
      const Account(
        role: AccountRole.client,
        client: ClientAccount(),
        language: AppLanguage.it,
      ),
    );
    expect(server.requests, hasLength(1));

    server.handler = (_) async => jsonResponse(<Object>[]);
    expect(
      await repository.fetchAccount('user-3'),
      const Account(role: AccountRole.client, client: ClientAccount()),
    );
  });

  test('un idioma que esta versión no conoce queda en null (manda el dispositivo)', () async {
    server.handler = (_) async => jsonResponse([
      {'role': 'client', 'locale': 'fr'},
    ]);
    expect((await repository.fetchAccount('user-2')).language, isNull);
  });

  group('updateLanguage', () {
    test('PATCH de locale en su perfil y también en user_metadata (email del código)', () async {
      await _signIn(server);
      server.handler = (request) async => switch (request.url.path) {
        '/rest/v1/profiles' => jsonResponse([
          {'locale': 'it'},
        ]),
        '/auth/v1/user' => jsonResponse(_user),
        _ => jsonResponse(<Object>[]),
      };

      await repository.updateLanguage(userId: 'user-1', language: AppLanguage.it);

      final profile = server.requests.firstWhere(
        (r) => r.url.path == '/rest/v1/profiles',
      );
      expect(profile.method, 'PATCH');
      expect(profile.url.queryParameters['id'], 'eq.user-1');
      expect(profile.url.queryParameters['select'], 'locale');
      // Solo el idioma: nunca el rol ni otros datos.
      expect(jsonBodyOf(profile), {'locale': 'it'});

      final metadata = server.requests.last;
      expect(metadata.method, 'PUT');
      expect(metadata.url.path, '/auth/v1/user');
      expect(jsonBodyOf(metadata), {'data': {'locale': 'it'}});
    });

    test('si el perfil no se actualiza (RLS o sin fila) → unavailable, sin tocar la metadata', () async {
      await _signIn(server);
      server.handler = (_) async => jsonResponse(<Object>[]);
      await expectLater(
        repository.updateLanguage(userId: 'user-1', language: AppLanguage.en),
        throwsA(
          isA<AccountFailure>().having(
            (f) => f.kind,
            'kind',
            AccountFailureKind.unavailable,
          ),
        ),
      );
      expect(server.requests.where((r) => r.url.path == '/auth/v1/user'), isEmpty);
    });

    test('error del servidor → unavailable', () async {
      server.handler = (_) async =>
          jsonResponse({'message': 'boom', 'code': 'XX000'}, status: 500);
      await expectLater(
        repository.updateLanguage(userId: 'user-1', language: AppLanguage.es),
        throwsA(isA<AccountFailure>()),
      );
    });

    test('si falla la metadata, el perfil igual queda guardado (no lanza)', () async {
      await _signIn(server);
      server.handler = (request) async => request.url.path == '/auth/v1/user'
          ? jsonResponse({'msg': 'boom'}, status: 500)
          : jsonResponse([
              {'locale': 'es'},
            ]);
      await repository.updateLanguage(userId: 'user-1', language: AppLanguage.es);
      expect(
        server.requests.map((r) => '${r.method} ${r.url.path}'),
        containsAllInOrder(['PATCH /rest/v1/profiles', 'PUT /auth/v1/user']),
      );
    });
  });

  test('rol chef con cocina pero sin poder leer su ficha → chefNotConfigured', () async {
    server.handler = (request) async => switch (request.url.path) {
      '/rest/v1/profiles' => jsonResponse([
        {'role': 'chef'},
      ]),
      '/rest/v1/rpc/current_chef_id' => jsonResponse(testChefId),
      _ => jsonResponse(<Object>[]),
    };
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

  group('«Mi cuenta» (auth.md §20)', () {
    Matcher unavailable() => throwsA(
      isA<AccountFailure>().having((f) => f.kind, 'kind', AccountFailureKind.unavailable),
    );

    test('fetchAccountDetails: su fila de account_details, o null si todavía no la tiene', () async {
      await _signIn(server);
      server.handler = (_) async => jsonResponse([
        {'first_name': 'Anna', 'phone': '+393401234567', 'privacy_version': '2026-11-28'},
      ]);
      expect(await repository.fetchAccountDetails(), {
        'first_name': 'Anna',
        'phone': '+393401234567',
        'privacy_version': '2026-11-28',
      });
      final read = server.last;
      expect(read.method, 'GET');
      expect(read.url.path, '/rest/v1/account_details');
      expect(read.url.queryParameters['profile_id'], 'eq.user-1');
      // Las columnas de los datos; nunca profile_id ni las fechas internas.
      expect(read.url.queryParameters['select']!.split(','), [
        'first_name', 'last_name', 'phone', 'birth_date', 'address_street', 'address_city', 'address_postal_code',
        'address_notes', 'favorite_season', 'heard_from', 'interests', 'preferred_days', 'household_size',
        'privacy_version',
      ]);

      server.handler = (_) async => jsonResponse(<Object>[]);
      expect(await repository.fetchAccountDetails(), isNull);
    });

    test('fetchAccountDetails sin sesión (no pregunta) o con error del servidor → unavailable', () async {
      await expectLater(repository.fetchAccountDetails(), unavailable());
      expect(server.requests, isEmpty);

      await _signIn(server);
      server.handler = (_) async => jsonResponse({'message': 'boom', 'code': 'XX000'}, status: 500);
      await expectLater(repository.fetchAccountDetails(), unavailable());
    });

    test('deleteMyAccount: POST a rpc/delete_my_account; un rechazo → unavailable', () async {
      await _signIn(server);
      server.handler = (_) async => jsonResponse(null);
      await repository.deleteMyAccount();
      expect(server.last.method, 'POST');
      expect(server.last.url.path, '/rest/v1/rpc/delete_my_account');

      server.handler = (_) async => jsonResponse({'message': 'kitchen_account', 'code': '42501'}, status: 403);
      await expectLater(repository.deleteMyAccount(), unavailable());
    });
  });
}

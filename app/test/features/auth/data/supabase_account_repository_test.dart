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

  test('cocinera: lee el rol, el idioma y su ficha en chefs', () async {
    server.handler = (request) async => switch (request.url.path) {
      '/rest/v1/profiles' => jsonResponse([
        {'role': 'chef', 'locale': 'es'},
      ]),
      '/rest/v1/chefs' => jsonResponse([
        {'id': testChefId, 'display_name': 'Evelyn'},
      ]),
      _ => jsonResponse(<Object>[]),
    };

    final account = await repository.fetchAccount('user-1');

    expect(account, chefAccountData.copyWith(language: AppLanguage.es));
    final profiles = server.requests.first.url;
    expect(profiles.path, '/rest/v1/profiles');
    expect(profiles.queryParameters['select'], 'role,locale');
    expect(profiles.queryParameters['id'], 'eq.user-1');
    final chefs = server.requests.last.url;
    expect(chefs.path, '/rest/v1/chefs');
    expect(chefs.queryParameters['select'], 'id,display_name');
    expect(chefs.queryParameters['profile_id'], 'eq.user-1');
  });

  test('cliente (o perfil sin rol): no consulta chefs', () async {
    server.handler = (_) async => jsonResponse([
      {'role': 'client', 'locale': 'it'},
    ]);
    expect(
      await repository.fetchAccount('user-2'),
      const Account(role: AccountRole.client, language: AppLanguage.it),
    );
    expect(server.requests, hasLength(1));

    server.handler = (_) async => jsonResponse(<Object>[]);
    expect(
      await repository.fetchAccount('user-3'),
      const Account(role: AccountRole.client),
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

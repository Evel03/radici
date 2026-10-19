// Login con código por email contra la API de Supabase Auth simulada.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../support/supabase_http_fake.dart';

/// Error de GoTrue (formato sin cabecera de versión: el código va en
/// `error_code`).
http.Response _authError(int status, String code, String message) =>
    jsonResponse({
      'code': status,
      'error_code': code,
      'msg': message,
    }, status: status);

void main() {
  late FakeSupabaseHttp server;
  late SupabaseAuthRepository repository;

  setUp(() {
    server = FakeSupabaseHttp((_) async => jsonResponse(<String, Object>{}));
    repository = SupabaseAuthRepository(server.client.auth);
  });

  tearDown(() => server.dispose());

  test('sendEmailCode pide el código por email y crea el usuario si no existe', () async {
    await repository.sendEmailCode('evelyn@example.test', locale: 'es');

    final request = server.last;
    expect(request.method, 'POST');
    expect(request.url.path, '/auth/v1/otp');
    final body = jsonBodyOf(request);
    expect(body['email'], 'evelyn@example.test');
    expect(body['create_user'], isTrue);
    // user_metadata.locale: idioma del email del código y del perfil.
    expect(body['data'], {'locale': 'es'});
  });

  test('sin idioma (o uno no soportado) no manda metadata', () async {
    await repository.sendEmailCode('evelyn@example.test');
    expect(jsonBodyOf(server.last)['data'], isEmpty);
    await repository.sendEmailCode('evelyn@example.test', locale: 'fr');
    expect(jsonBodyOf(server.last)['data'], isEmpty);
  });

  test('verifyEmailCode verifica con type=email y abre la sesión', () async {
    server.handler = (request) async => request.url.path == '/auth/v1/verify'
        ? jsonResponse(fakeSessionJson('user-1', 'evelyn@example.test'))
        : jsonResponse(<String, Object>{});
    final changes = <AppUser?>[];
    final subscription = repository.userChanges().listen(changes.add);

    expect(repository.currentUser, isNull);
    await repository.verifyEmailCode(email: 'evelyn@example.test', code: '123456');

    final body = jsonBodyOf(server.last);
    expect(server.last.url.path, '/auth/v1/verify');
    expect(body['email'], 'evelyn@example.test');
    expect(body['token'], '123456');
    expect(body['type'], 'email');
    expect(
      repository.currentUser,
      const AppUser(id: 'user-1', email: 'evelyn@example.test'),
    );
    await pumpEventQueue();
    expect(changes.last?.id, 'user-1');

    // Salir: la sesión se borra y se avisa con null.
    await repository.signOut();
    await pumpEventQueue();
    expect(repository.currentUser, isNull);
    expect(changes.last, isNull);
    await subscription.cancel();
  });

  group('errores', () {
    Future<AuthFailureKind> failureOf(Future<void> Function() action) async {
      try {
        await action();
      } on AuthFailure catch (failure) {
        return failure.kind;
      }
      fail('Se esperaba un AuthFailure');
    }

    test('código vencido o incorrecto', () async {
      server.handler = (_) async =>
          _authError(403, 'otp_expired', 'Token has expired or is invalid');
      expect(
        await failureOf(
          () => repository.verifyEmailCode(email: 'e@x.test', code: '000000'),
        ),
        AuthFailureKind.invalidCode,
      );
    });

    test('demasiados pedidos de código', () async {
      server.handler = (_) async => _authError(
        429,
        'over_email_send_rate_limit',
        'For security purposes, you can only request this after 60 seconds.',
      );
      expect(
        await failureOf(() => repository.sendEmailCode('e@x.test')),
        AuthFailureKind.rateLimited,
      );
    });

    test('altas desactivadas', () async {
      server.handler = (_) async =>
          _authError(422, 'otp_disabled', 'Signups not allowed for otp');
      expect(
        await failureOf(() => repository.sendEmailCode('e@x.test')),
        AuthFailureKind.notAllowed,
      );
    });

    test('sin conexión o error del servidor', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      expect(
        await failureOf(() => repository.sendEmailCode('e@x.test')),
        AuthFailureKind.network,
      );
      server.handler = (_) async => jsonResponse({'msg': 'boom'}, status: 502);
      expect(
        await failureOf(() => repository.sendEmailCode('e@x.test')),
        AuthFailureKind.network,
      );
    });
  });

  group('authFailureKindOf', () {
    test('sin código de error (GoTrue viejo)', () {
      expect(
        authFailureKindOf(const AuthApiException('x', statusCode: '429')),
        AuthFailureKind.rateLimited,
      );
      expect(
        authFailureKindOf(
          const AuthApiException('x', statusCode: '403'),
          verifying: true,
        ),
        AuthFailureKind.invalidCode,
      );
      expect(
        authFailureKindOf(const AuthApiException('x', statusCode: '403')),
        AuthFailureKind.unknown,
      );
    });

    test('otros errores', () {
      expect(
        authFailureKindOf(
          const AuthApiException('x', code: 'email_address_invalid'),
        ),
        AuthFailureKind.invalidEmail,
      );
      expect(authFailureKindOf(StateError('x')), AuthFailureKind.unknown);
    });
  });

  test('sin backend: no hay sesión y pedir código avisa', () async {
    const repository = NoBackendAuthRepository();
    expect(repository.currentUser, isNull);
    await expectLater(
      repository.sendEmailCode('e@x.test'),
      throwsA(
        isA<AuthFailure>().having(
          (f) => f.kind,
          'kind',
          AuthFailureKind.noBackend,
        ),
      ),
    );
  });
}

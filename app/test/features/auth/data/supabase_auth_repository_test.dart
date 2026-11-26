// Login con código por email, contraseña, alta, recuperación y cambio de
// contraseña contra la API de Supabase Auth simulada.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/password_rules.dart';
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

/// Error de GoTrue con la cabecera de versión (como responde hoy: el código
/// va en `code`). Así llega el 403 del hook de la cocina.
http.Response _versionedError(
  int status,
  String code,
  String message, {
  Map<String, Object?> extra = const {},
}) => http.Response(
  jsonEncode({'code': code, 'message': message, ...extra}),
  status,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    'x-supabase-api-version': '2024-01-01',
  },
);

void main() {
  late FakeSupabaseHttp server;
  late SupabaseAuthRepository repository;

  setUp(() {
    server = FakeSupabaseHttp((_) async => jsonResponse(<String, Object>{}));
    repository = SupabaseAuthRepository(server.client.auth);
  });

  tearDown(() => server.dispose());

  test('sendEmailCode pide el código por email sin crear usuarios', () async {
    await repository.sendEmailCode('evelyn@example.test', locale: 'es');

    final request = server.last;
    expect(request.method, 'POST');
    expect(request.url.path, '/auth/v1/otp');
    final body = jsonBodyOf(request);
    expect(body['email'], 'evelyn@example.test');
    // Hasta el área de clientes (M2) solo entra quien ya tiene usuario (Evelyn,
    // creada desde el panel): un email desconocido no crea una cuenta.
    expect(body['create_user'], isFalse);
    // user_metadata.locale: idioma del email del código y del perfil.
    expect(body['data'], {'locale': 'es'});
  });

  test('con captchaToken lo manda en gotrue_meta_security (Auth lo verifica si tiene el captcha prendido)', () async {
    await repository.sendEmailCode('evelyn@example.test', locale: 'it', captchaToken: 'tok.en-1');
    final body = jsonBodyOf(server.last);
    expect(server.last.url.path, '/auth/v1/otp');
    expect(body['gotrue_meta_security'], {'captcha_token': 'tok.en-1'});
    // El token no se mezcla con lo demás del pedido.
    expect(body['email'], 'evelyn@example.test');
    expect(body['data'], {'locale': 'it'});
  });

  test('sin captchaToken, el campo viaja vacío (Auth sin captcha no lo mira)', () async {
    await repository.sendEmailCode('evelyn@example.test');
    expect(jsonBodyOf(server.last)['gotrue_meta_security'], {'captcha_token': null});
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

  group('contraseña, alta y recuperación (las clientas)', () {
    test('signInWithPassword: grant_type=password con el captcha, y abre la sesión', () async {
      server.handler = (request) async => request.url.path == '/auth/v1/token'
          ? jsonResponse(fakeSessionJson('user-2', 'cliente@example.test'))
          : jsonResponse(<String, Object>{});
      await repository.signInWithPassword(
        email: 'cliente@example.test',
        password: 'Prova12345',
        captchaToken: 'tok-1',
      );
      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/auth/v1/token');
      expect(request.url.queryParameters['grant_type'], 'password');
      final body = jsonBodyOf(request);
      expect(body['email'], 'cliente@example.test');
      expect(body['password'], 'Prova12345');
      expect(body['gotrue_meta_security'], {'captcha_token': 'tok-1'});
      expect(repository.currentUser?.id, 'user-2');
    });

    test('signUp: una contraseña al azar que cumple la regla, en data solo locale, y el captcha', () async {
      await repository.signUp(email: 'nueva@example.test', locale: 'es', captchaToken: 'tok-2');
      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/auth/v1/signup');
      // Sin redirect_to: las plantillas llevan a /accesso/ con el token_hash.
      expect(request.url.queryParameters.containsKey('redirect_to'), isFalse);
      final body = jsonBodyOf(request);
      expect(body['email'], 'nueva@example.test');
      expect(body['data'], {'locale': 'es'});
      expect(body['gotrue_meta_security'], {'captcha_token': 'tok-2'});
      final password = body['password'] as String;
      expect(password, hasLength(signupPasswordLength));
      expect(passwordProblem(password), isNull);

      // Otra alta, otra contraseña: nunca una fija.
      await repository.signUp(email: 'otra@example.test', locale: 'fr');
      final second = jsonBodyOf(server.last);
      expect(second['password'], isNot(password));
      expect(second['data'], isEmpty, reason: 'un idioma no soportado no se manda');
    });

    test('requestPasswordReset: /recover con el email y el captcha', () async {
      await repository.requestPasswordReset('cliente@example.test', captchaToken: 'tok-3');
      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/auth/v1/recover');
      final body = jsonBodyOf(request);
      expect(body['email'], 'cliente@example.test');
      expect(body['gotrue_meta_security'], {'captcha_token': 'tok-3'});
    });

    test('resendSignupEmail: /resend de tipo signup con el captcha', () async {
      await repository.resendSignupEmail('nueva@example.test', captchaToken: 'tok-4');
      final request = server.last;
      expect(request.url.path, '/auth/v1/resend');
      final body = jsonBodyOf(request);
      expect(body['email'], 'nueva@example.test');
      expect(body['type'], 'signup');
      expect(body['gotrue_meta_security'], {'captcha_token': 'tok-4'});
    });

    test('changePassword: PUT /user con la nueva y la actual (current_password)', () async {
      await signInFake(server, userId: 'user-3', email: 'cliente@example.test');
      server.handler = (_) async => jsonResponse(fakeUserJson('user-3', 'cliente@example.test'));
      await repository.changePassword(currentPassword: 'Vecchia1234', newPassword: 'Nuova12345');
      final request = server.last;
      expect(request.method, 'PUT');
      expect(request.url.path, '/auth/v1/user');
      final body = jsonBodyOf(request);
      expect(body['password'], 'Nuova12345');
      expect(body['current_password'], 'Vecchia1234');
      expect(request.headers['authorization'], startsWith('Bearer '));
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

      Future<AuthFailureKind> signInWith(http.Response response) {
        server.handler = (_) async => response;
        return failureOf(
          () => repository.signInWithPassword(email: 'e@x.test', password: 'Prova12345'),
        );
      }

      test('email o contraseña incorrectos, o sin confirmar: el mismo aviso', () async {
        expect(
          await signInWith(_authError(400, 'invalid_credentials', 'Invalid login credentials')),
          AuthFailureKind.invalidCredentials,
        );
        expect(
          await signInWith(_versionedError(400, 'invalid_credentials', 'Invalid login credentials')),
          AuthFailureKind.invalidCredentials,
        );
        expect(
          await signInWith(_versionedError(400, 'email_not_confirmed', 'Email not confirmed')),
          AuthFailureKind.invalidCredentials,
        );
      });

      test('una cuenta de la cocina con contraseña: el 403 del hook (kitchen_code_only)', () async {
        // Medido en GoTrue v2.197 con el hook prendido: {"code":"unknown","message":"kitchen_code_only"}.
        expect(
          await signInWith(_versionedError(403, 'unknown', 'kitchen_code_only')),
          AuthFailureKind.kitchenCodeOnly,
        );
      });

      test('altas cerradas', () async {
        server.handler = (_) async => _versionedError(422, 'signup_disabled', 'Signups not allowed for this instance');
        expect(
          await failureOf(() => repository.signUp(email: 'e@x.test')),
          AuthFailureKind.signupClosed,
        );
      });

      test('contraseña nueva: débil, igual a la de antes, o la actual incorrecta', () async {
        await signInFake(server, userId: 'user-4', email: 'cliente@example.test');
        Future<AuthFailureKind> changeWith(http.Response response) {
          server.handler = (_) async => response;
          return failureOf(
            () => repository.changePassword(currentPassword: 'Vecchia1234', newPassword: 'Nuova12345'),
          );
        }

        expect(
          await changeWith(
            _versionedError(
              422,
              'weak_password',
              'Password should contain at least one character of each: abc, 0123456789.',
              extra: {
                'weak_password': {
                  'reasons': ['characters'],
                },
              },
            ),
          ),
          AuthFailureKind.weakPassword,
        );
        expect(
          await changeWith(_versionedError(422, 'same_password', 'New password should be different from the old password.')),
          AuthFailureKind.samePassword,
        );
        // GoTrue v2.197 (medido en PR14) dice current_password_invalid; las
        // versiones más nuevas, current_password_mismatch.
        expect(
          await changeWith(_versionedError(400, 'current_password_invalid', 'Current password required')),
          AuthFailureKind.wrongCurrentPassword,
        );
        expect(
          await changeWith(_versionedError(400, 'current_password_mismatch', 'Current password does not match')),
          AuthFailureKind.wrongCurrentPassword,
        );
      });

      test('recuperación con demasiados pedidos seguidos', () async {
        server.handler = (_) async => _versionedError(
          429,
          'over_email_send_rate_limit',
          'For security purposes, you can only request this after 60 seconds.',
        );
        expect(
          await failureOf(() => repository.requestPasswordReset('e@x.test')),
          AuthFailureKind.rateLimited,
        );
      });

      test('sin backend: cada pedido nuevo avisa noBackend', () async {
        const offline = NoBackendAuthRepository();
        expect(
          await failureOf(() => offline.signInWithPassword(email: 'e@x.test', password: 'x')),
          AuthFailureKind.noBackend,
        );
        expect(await failureOf(() => offline.signUp(email: 'e@x.test')), AuthFailureKind.noBackend);
        expect(await failureOf(() => offline.requestPasswordReset('e@x.test')), AuthFailureKind.noBackend);
        expect(await failureOf(() => offline.resendSignupEmail('e@x.test')), AuthFailureKind.noBackend);
        expect(
          await failureOf(() => offline.changePassword(currentPassword: 'a', newPassword: 'b')),
          AuthFailureKind.noBackend,
        );
      });
    });
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
      // Auth rechazó el token del captcha (PR11): el mismo aviso que sin token.
      expect(
        authFailureKindOf(
          const AuthApiException('captcha protection: request disallowed (timeout-or-duplicate)', statusCode: '400', code: 'captcha_failed'),
        ),
        AuthFailureKind.captcha,
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

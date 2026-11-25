// Qué errores de Auth llegan al login (AuthRepository.failures): los de un
// link de acceso con error; no los de la red ni los de renovar la sesión.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('un link vencido o ya usado llega al login', () {
    // getSessionFromUrl: statusCode = error_code de la URL, code = error.
    final failure = authLinkFailureOf(
      const AuthException(
        'Email link is invalid or has expired',
        statusCode: 'otp_expired',
        code: 'access_denied',
      ),
    );
    expect(failure?.kind, AuthFailureKind.unknown);
    expect(
      authLinkFailureOf(const AuthException('x'))?.kind,
      AuthFailureKind.unknown,
    );
    expect(
      authLinkFailureOf(
        const AuthException('x', statusCode: 'over_email_send_rate_limit'),
      )?.kind,
      AuthFailureKind.rateLimited,
    );
  });

  test('sin red o al renovar la sesión, nada para el login', () {
    expect(
      authLinkFailureOf(AuthRetryableFetchException(message: 'x')),
      isNull,
    );
    expect(authLinkFailureOf(Exception('x')), isNull);
    for (final code in [
      'refresh_token_not_found',
      'refresh_token_already_used',
      'session_not_found',
      'session_expired',
      'bad_jwt',
    ]) {
      expect(
        authLinkFailureOf(AuthException('x', statusCode: '400', code: code)),
        isNull,
        reason: code,
      );
    }
  });
}

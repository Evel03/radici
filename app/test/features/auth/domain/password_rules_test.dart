// La regla de las contraseñas: la misma que Auth y /accesso/ (los mismos
// casos que auth-config.test.ts) y la contraseña al azar del alta.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/domain/password_rules.dart';

void main() {
  test('10 o más caracteres, con letras (a-z, A-Z) y dígitos: los casos de auth-config.test.ts', () {
    for (final (password, ok) in [
      ('abcdefghi1', true),
      ('ABCDEFGHI1', true),
      ('abcdefghij', false),
      ('1234567890', false),
      ('abcdefgh1', false),
      ('èèèèèèèèè1', false),
    ]) {
      expect(passwordProblem(password) == null, ok, reason: password);
    }
  });

  test('qué falta, en el orden de /accesso/: corta, larga (más de 72 bytes), letras y números', () {
    expect(passwordProblem('abc1'), PasswordProblem.tooShort);
    // 10 caracteres de 2 bytes cuentan como 10 (runes), no como 20.
    expect(passwordProblem('èèèèèèèèèè'), PasswordProblem.lettersDigits);
    expect(passwordProblem('a1${'è' * 36}'), PasswordProblem.tooLong, reason: '74 bytes');
    expect(passwordProblem('a1${'b' * 70}'), isNull, reason: '72 bytes justos');
    expect(passwordProblem('soloLetrasLargas'), PasswordProblem.lettersDigits);
  });

  test('la contraseña al azar del alta: 40 caracteres, cumple la regla y nunca se repite', () {
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      final password = generateSignupPassword();
      expect(password, hasLength(signupPasswordLength));
      expect(password, matches(RegExp(r'^[A-Za-z0-9]+$')));
      expect(passwordProblem(password), isNull);
      seen.add(password);
    }
    expect(seen, hasLength(200));
  });

  test('si una tirada no trae letras o dígitos, vuelve a tirar', () {
    // Primero 40 veces el índice del "0" (solo dígitos), después algo válido.
    final random = _ScriptedRandom([...List.filled(40, 52), 0, ...List.filled(39, 60)]);
    final password = generateSignupPassword(random);
    expect(password, 'a${'8' * 39}');
  });
}

/// Devuelve los índices en orden (para probar el reintento).
class _ScriptedRandom implements Random {
  _ScriptedRandom(this._values);

  final List<int> _values;
  int _next = 0;

  @override
  int nextInt(int max) => _values[_next++] % max;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

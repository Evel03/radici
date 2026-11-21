// El teléfono escrito o pegado en la app (core/phone.dart, fuera de la copia
// de la regla compartida, que prueba phone_test.dart): cleanOneLine da lo
// mismo que la de _shared/public_request.ts, y phoneFromInput acepta lo que
// iOS pega desde Contactos o el Teléfono (el número envuelto en marcas
// invisibles de dirección). Los caracteres invisibles van con escapes, nunca
// tal cual en el archivo.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/phone.dart';

import '../support/repo_files.dart';

/// Casos `normalizePhone("…")` del test de TS: todo lo que se ve en pantalla.
Iterable<String> _visibleCasesFromTsTests() {
  final source = findRepoFile(
    'supabase/functions/_shared/public_request.test.ts',
  ).readAsStringSync();
  return RegExp(
    r'normalizePhone\("([^"]*)"\)',
  ).allMatches(source).map((m) => m.group(1)!).toSet();
}

void main() {
  group('cleanOneLine, como la de TS', () {
    // Los resultados son los de cleanOneLine de public_request.ts con las
    // mismas entradas.
    for (final (input, expected) in [
      (' a \n b\t c ', 'a b c'),
      ('\u202aAnna\u202c  Rossi', 'Anna Rossi'),
      ('x\u202ey', 'x y'),
      ('\u2066Via Roma\u2069 1', 'Via Roma 1'),
      ('a\u0000b\u007fc', 'a b c'),
      ('  Città   Alta  ', 'Città Alta'),
      ('\u00a0Giulia\u00a0Rossi\u202f', 'Giulia Rossi'),
    ]) {
      test('${input.codeUnits} → "$expected"', () {
        expect(cleanOneLine(input), expected);
      });
    }
  });

  group('phoneFromInput', () {
    for (final (label, input) in [
      ('limpio', '+39 333 123 4567'),
      ('con U+00A0', '+39\u00a0333\u00a0123\u00a04567'),
      ('con U+202F', '+39\u202f333\u202f123\u202f4567'),
      ('entre U+202A y U+202C (Contactos)', '\u202a+39 333 123 4567\u202c'),
      ('entre U+202D y U+202C', '\u202d+39 333 123 4567\u202c'),
      ('con U+200E', '\u200e+39 333 123 4567'),
      ('con U+200F', '+39 333 123 4567\u200f'),
      ('con U+FEFF', '\ufeff+39 333 123 4567'),
      ('sin prefijo, envuelto', '\u202a333 123 4567\u202c'),
    ]) {
      test('$label da +393331234567', () {
        expect(phoneFromInput(input), '+393331234567');
      });
    }

    test(
      'normalizePhone solo no acepta el número envuelto: por eso la limpieza',
      () {
        expect(normalizePhone('\u202a+39 333 123 4567\u202c'), isNull);
        expect(normalizePhone('\u200e+39 333 123 4567'), isNull);
      },
    );

    test('con todo lo que se ve en pantalla da lo mismo que normalizePhone', () {
      final cases = _visibleCasesFromTsTests();
      expect(cases.length, greaterThanOrEqualTo(11));
      for (final input in [
        ...cases,
        '333.123.4567',
        '0039 333-123-4567',
        '612345678',
        'hola',
        '',
        '   ',
      ]) {
        expect(phoneFromInput(input), normalizePhone(input), reason: input);
      }
    });

    test('lo que no es un teléfono sigue siendo null', () {
      expect(phoneFromInput('\u202a\u202c'), isNull);
      expect(phoneFromInput('\u202a612 345 678\u202c'), isNull);
      expect(phoneFromInput('Giulia'), isNull);
    });
  });

  test('withoutFormatChars saca las marcas invisibles y nada más', () {
    expect(withoutFormatChars('\u200e+39\u200b 333\ufeff'), '+39 333');
    expect(withoutFormatChars('Città Alta'), 'Città Alta');
  });
}

// La copia Dart de normalizePhone tiene que dar lo mismo que la de TS
// (supabase/functions/_shared/public_request.ts).
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/core/phone.dart';

import '../support/repo_files.dart';

const _tsTestsPath = 'supabase/functions/_shared/public_request.test.ts';

/// Casos `assert.equal(normalizePhone("…"), "…" | null)` del test de TS.
/// Leerlos del archivo mantiene las dos copias alineadas: un caso nuevo en TS
/// también se prueba acá.
Map<String, String?> _casesFromTsTests() {
  final source = findRepoFile(_tsTestsPath).readAsStringSync();
  final pattern = RegExp(
    r'assert\.equal\(\s*normalizePhone\("([^"]*)"\),\s*(?:"([^"]*)"|(null))',
  );
  return {
    for (final match in pattern.allMatches(source))
      match.group(1)!: match.group(3) == null ? match.group(2) : null,
  };
}

void main() {
  group('mismos casos que public_request.test.ts', () {
    final cases = _casesFromTsTests();

    test('el test de TS tiene casos de normalizePhone', () {
      // Si cambia el formato del test de TS, este parser deja de encontrarlos.
      expect(cases.length, greaterThanOrEqualTo(11));
    });

    cases.forEach((input, expected) {
      test('"$input" → $expected', () {
        expect(normalizePhone(input), expected);
      });
    });
  });

  test('formatos italianos sin prefijo y números internacionales', () {
    expect(normalizePhone('+39 333 123 4567'), '+393331234567');
    expect(normalizePhone('0039 333-123-4567'), '+393331234567');
    expect(normalizePhone('333 1234567'), '+393331234567');
    expect(normalizePhone('393447936567'), '+393447936567');
    expect(normalizePhone('035 123456'), '+39035123456');
    expect(normalizePhone('+34 612 345 678'), '+34612345678');
    expect(normalizePhone('(+54) 9 11 2345-6789'), '+5491123456789');
    expect(normalizePhone('+54 9 11 2345-6789'), '+5491123456789');
  });

  test('inválidos: sin prefijo y no italiano, prefijo 0, texto', () {
    expect(normalizePhone('612345678'), isNull);
    expect(normalizePhone('+0 123'), isNull);
    expect(normalizePhone('hola'), isNull);
    expect(normalizePhone(''), isNull);
    expect(normalizePhone('+39 333'), isNull, reason: 'demasiado corto');
    expect(
      normalizePhone('+1234567890123456'),
      isNull,
      reason: 'más de 15 cifras',
    );
  });

  test('ignora espacios de cualquier tipo, puntos y barras', () {
    expect(normalizePhone(' 333.123.4567 '), '+393331234567');
    expect(normalizePhone('333/1234567'), '+393331234567');
    // Espacio duro (U+00A0), como el que pega un teléfono copiado de la web.
    expect(normalizePhone('333 123 4567'), '+393331234567');
  });
}

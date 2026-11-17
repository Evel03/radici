// Ids generados en el teléfono (uuid v4): la clave de idempotencia de cada
// intento de reserva (requestKey) y el id del plato nuevo (save_recipe). Tienen
// la forma que aceptan los dos y no se repiten.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/uuid.dart';

final RegExp _v4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  test('forma de uuid v4, en minúsculas', () {
    for (var i = 0; i < 200; i++) {
      expect(uuidV4(), matches(_v4));
    }
  });

  test('no se repiten', () {
    final ids = {for (var i = 0; i < 5000; i++) uuidV4()};
    expect(ids, hasLength(5000));
  });

  test('con un Random fijo sale siempre el mismo (para los tests)', () {
    expect(uuidV4(Random(7)), uuidV4(Random(7)));
    expect(uuidV4(Random(7)), matches(_v4));
  });

  test('isUuid acepta mayúsculas o minúsculas y nada más', () {
    expect(isUuid('0e5b3c1a-2f4d-4a6b-8c9d-0123456789ab'), isTrue);
    expect(isUuid('0E5B3C1A-2F4D-4A6B-8C9D-0123456789AB'), isTrue);
    expect(isUuid('0e5b3c1a2f4d4a6b8c9d0123456789ab'), isFalse);
    expect(isUuid('nuovo'), isFalse);
    expect(isUuid(''), isFalse);
  });

  test('lo que genera uuidV4 lo acepta isUuid (save_recipe y la requestKey de chef)', () {
    for (var i = 0; i < 200; i++) {
      expect(isUuid(uuidV4()), isTrue);
    }
  });
}

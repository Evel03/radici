// Claves de idempotencia: UUID v4 al azar.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/uuid.dart';

final RegExp _v4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  test('tiene la forma de un UUID v4', () {
    for (var i = 0; i < 50; i++) {
      expect(uuidV4(), matches(_v4));
    }
  });

  test('cada una es distinta', () {
    final keys = {for (var i = 0; i < 200; i++) uuidV4()};
    expect(keys, hasLength(200));
  });

  test('con la misma semilla da la misma (para los tests)', () {
    expect(uuidV4(Random(7)), uuidV4(Random(7)));
    expect(uuidV4(Random(7)), matches(_v4));
  });
}

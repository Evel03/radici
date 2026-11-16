// Ids generados en el teléfono (uuid v4). Un guardado que se reintenta manda
// el mismo id, así nunca duplica: el plato nuevo del catálogo (save_recipe) y,
// más adelante, los ítems de la lista de compras.
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// [value] tiene la forma de un uuid (la que exige save_recipe).
bool isUuid(String value) => _uuid.hasMatch(value);

/// Un uuid v4 al azar, en minúsculas. [random] es para los tests; por
/// defecto, [Random.secure] (en la web, crypto.getRandomValues).
String uuidV4([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // versión 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variante RFC 4122
  final hex = [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Fábrica de ids nuevos: los tests la reemplazan por una fija.
final newIdProvider = Provider<String Function()>((ref) => uuidV4);

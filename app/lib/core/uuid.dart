// UUID v4 al azar (RFC 9562) para las claves de idempotencia: la app genera
// una por intento y la repite en sus reintentos (contrato
// docs/contracts/chef-api.md §4). Dart puro, sin dependencias.
import 'dart:math';

/// Un UUID v4 en minúsculas. [random], solo para los tests; por defecto,
/// `Random.secure()` (en la web, `crypto.getRandomValues`).
String uuidV4([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // versión 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variante RFC
  final hex = [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')]
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

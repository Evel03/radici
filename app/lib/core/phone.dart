// Normalización de teléfonos: copia en Dart de `normalizePhone` de
// supabase/functions/_shared/public_request.ts (la fuente de verdad).
// Se usa para armar los links de WhatsApp (wa.me) y de llamada (tel:) a partir
// de `clients.contact_phone`, que se guarda tal como lo escribió el cliente.
// test/core/phone_test.dart corre los mismos casos que public_request.test.ts.
//
// Dart puro: las RegExp de Dart siguen la semántica de JavaScript, así que las
// expresiones son las mismas que en TS.

final RegExp _separators = RegExp(r'[\s().\/-]');
final RegExp _italianMobile = RegExp(r'^3\d{8,9}$');
final RegExp _italianLandline = RegExp(r'^0\d{5,10}$');
final RegExp _italianWithoutPlus = RegExp(r'^39\d{9,11}$');
final RegExp _e164Digits = RegExp(r'^[1-9]\d{7,14}$');

/// Normaliza un teléfono a `+<dígitos>` (E.164) o devuelve `null` si no se
/// puede.
///
/// Sin prefijo internacional se asume Italia solo para formatos italianos
/// inequívocos: móvil de 9–10 cifras que empieza con 3, o fijo que empieza
/// con 0. Cualquier otro número sin "+" o "00" es inválido.
String? normalizePhone(String raw) {
  final compact = raw.trim().replaceAll(_separators, '');
  final String digits;
  if (compact.startsWith('+')) {
    digits = compact.substring(1);
  } else if (compact.startsWith('00')) {
    digits = compact.substring(2);
  } else if (_italianMobile.hasMatch(compact) ||
      _italianLandline.hasMatch(compact)) {
    digits = '39$compact';
  } else if (_italianWithoutPlus.hasMatch(compact)) {
    // Ya trae el 39, sin "+".
    digits = compact;
  } else {
    return null;
  }
  return _e164Digits.hasMatch(digits) ? '+$digits' : null;
}

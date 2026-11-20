// Normalización de teléfonos: copia en Dart de `normalizePhone` de
// supabase/functions/_shared/public_request.ts (la fuente de verdad).
// Se usa para armar los links de WhatsApp (wa.me) y de llamada (tel:) a partir
// de `clients.contact_phone`, que se guarda tal como lo escribió el cliente.
// test/core/phone_test.dart corre los mismos casos que public_request.test.ts.
// Al final, lo que limpia un teléfono escrito o pegado en la app
// (phoneFromInput), con su propio test (test/core/phone_input_test.dart).
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

// ---------------------------------------------------------------------------
// Lo que se escribe o se pega en la app (fuera de la copia de la regla
// compartida).
// ---------------------------------------------------------------------------

final RegExp _controlsAndBidi = RegExp(
  r'[\u0000-\u001F\u007F\u202a-\u202e\u2066-\u2069]',
);
final RegExp _spaces = RegExp(r'\s+');

/// Caracteres de formato (categoría Cf): no se ven en pantalla, como las
/// marcas de dirección U+200E y U+200F o U+FEFF.
final RegExp _formatChars = RegExp(r'\p{Cf}', unicode: true);

/// Copia de `cleanOneLine` de _shared/public_request.ts, con la que el
/// servidor limpia un campo de una línea antes de validarlo: los caracteres
/// de control y las marcas de dirección (U+202A–U+202E y U+2066–U+2069) pasan
/// a espacio, los espacios seguidos quedan en uno y se recortan los bordes.
String cleanOneLine(String raw) =>
    raw.replaceAll(_controlsAndBidi, ' ').replaceAll(_spaces, ' ').trim();

/// [text] sin los caracteres de formato (Cf).
String withoutFormatChars(String text) => text.replaceAll(_formatChars, '');

/// Un teléfono escrito o pegado, en E.164, o null si no se puede normalizar.
/// Al copiar un número de Contactos o del Teléfono, iOS lo envuelve en marcas
/// invisibles de dirección (U+202A…U+202C, U+200E) que [normalizePhone] no
/// saca: «+39 333 123 4567» entre U+202A y U+202C daba null. Con lo que se ve
/// en pantalla da lo mismo que [normalizePhone].
String? phoneFromInput(String raw) =>
    normalizePhone(withoutFormatChars(cleanOneLine(raw)));

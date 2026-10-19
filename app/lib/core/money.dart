// Formateo de importes. Los importes viajan y se calculan siempre en
// centavos (int); acá solo se convierten a texto para mostrar.
import 'package:intl/intl.dart';

/// Moneda del negocio (Bergamo).
const String businessCurrency = 'EUR';

/// Formatea [cents] como importe en euros según [locale] (ej. `it`, `es`, `en`).
///
/// `it`: `141,00 €` · `es`: `141,00 €` · `en`: `€141.00`.
String formatCents(int cents, {required String locale}) {
  final format = NumberFormat.currency(
    locale: locale,
    name: businessCurrency,
    symbol: '€',
    decimalDigits: 2,
  );
  // La división a double es solo para el texto: nunca se opera con el
  // resultado. Los importes del negocio están lejos de 2^53 centavos, donde
  // double deja de representar enteros exactos.
  return format.format(cents / 100);
}

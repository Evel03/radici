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

final RegExp _ignoredInAmount = RegExp('[\\s  €]');
final RegExp _wholeEuros = RegExp(r'^\d+$');
final RegExp _decimalEuros = RegExp(r'^(\d+)[.,](\d{1,2})$');
final RegExp _groupedEuros = RegExp(r'^\d{1,3}([.,])\d{3}(?:\1\d{3})*$');
final RegExp _groupedDecimalEuros = RegExp(
  r'^(\d{1,3}([.,])\d{3}(?:\2\d{3})*)([.,])(\d{1,2})$',
);

/// Más de 999.999.999 € no es un importe del negocio (y así el entero nunca
/// se desborda, tampoco en la web).
const int _maxEuroDigits = 9;

/// Lee un importe en euros como lo escribe la cocinera y lo devuelve en
/// centavos, sin pasar por `double`: "560", "560,50", "560.5", "1.062,40",
/// "1,062.40" o "560 €". Coma o punto como decimal (hasta dos decimales); con
/// tres cifras detrás, es separador de miles. null si no es un importe (vacío,
/// negativo, más de dos decimales, letras…).
int? parseEuroCents(String input) {
  final text = input.replaceAll(_ignoredInAmount, '');
  final String euros;
  var cents = '';
  if (_wholeEuros.hasMatch(text)) {
    euros = text;
  } else if (_decimalEuros.firstMatch(text) case final match?) {
    euros = match.group(1)!;
    cents = match.group(2)!;
  } else if (_groupedEuros.firstMatch(text) case final match?) {
    euros = text.replaceAll(match.group(1)!, '');
  } else if (_groupedDecimalEuros.firstMatch(text) case final match?
      when match.group(2) != match.group(3)) {
    euros = match.group(1)!.replaceAll(match.group(2)!, '');
    cents = match.group(4)!;
  } else {
    return null;
  }
  if (euros.length > _maxEuroDigits) return null;
  return int.parse(euros) * 100 + int.parse(cents.padRight(2, '0'));
}

/// Centavos como texto para un campo de importe, sin símbolo ni separador de
/// miles y con decimales solo si los hay: "560", "560,50" ("560.50" en
/// inglés). [parseEuroCents] lo vuelve a leer igual.
String formatCentsForInput(int cents, {required String locale}) {
  final euros = cents ~/ 100;
  final rest = cents % 100;
  if (rest == 0) return '$euros';
  final separator = NumberFormat.decimalPattern(locale).symbols.DECIMAL_SEP;
  return '$euros$separator${rest.toString().padLeft(2, '0')}';
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/core/money.dart';

// intl separa número y símbolo con un espacio duro (U+00A0).
const _nbsp = ' ';

void main() {
  test('formatea centavos según el idioma', () {
    expect(formatCents(14100, locale: 'it'), '141,00$_nbsp€');
    expect(formatCents(14100, locale: 'es'), '141,00$_nbsp€');
    expect(formatCents(14100, locale: 'en'), '€141.00');
  });

  test('conserva los centavos y separa miles', () {
    expect(formatCents(8488, locale: 'it'), '84,88$_nbsp€');
    expect(formatCents(123456, locale: 'it'), '1.234,56$_nbsp€');
    expect(formatCents(123456, locale: 'en'), '€1,234.56');
    expect(formatCents(5, locale: 'it'), '0,05$_nbsp€');
    expect(formatCents(0, locale: 'en'), '€0.00');
  });

  test('acepta locales con región', () {
    expect(formatCents(437, locale: 'it_IT'), '4,37$_nbsp€');
  });
}

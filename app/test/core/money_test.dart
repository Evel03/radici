import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/money.dart';

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

  group('parseEuroCents: lo que escribe la cocinera, a centavos sin double', () {
    test('euros enteros y con decimales, con coma o con punto', () {
      expect(parseEuroCents('560'), 56000);
      expect(parseEuroCents('0'), 0);
      expect(parseEuroCents('560,50'), 56050);
      expect(parseEuroCents('560.5'), 56050);
      expect(parseEuroCents('62,4'), 6240);
      expect(parseEuroCents('0,05'), 5);
      expect(parseEuroCents('140,00'), 14000);
    });

    test('miles con punto o coma, con o sin decimales', () {
      expect(parseEuroCents('1.062,40'), 106240);
      expect(parseEuroCents('1,062.40'), 106240);
      expect(parseEuroCents('1.060'), 106000);
      expect(parseEuroCents('1,060'), 106000);
      expect(parseEuroCents('1.000.000'), 100000000);
      // Tres cifras detrás de un solo separador son miles, no decimales: la
      // hoja lo muestra como importe (y avisa si pasa el tope).
      expect(parseEuroCents('560,505'), 56050500);
    });

    test('ignora espacios y el símbolo del euro', () {
      expect(parseEuroCents(' 560 '), 56000);
      expect(parseEuroCents('560 €'), 56000);
      expect(parseEuroCents('€560,50'), 56050);
      expect(parseEuroCents('560$_nbsp€'), 56000);
    });

    test('rechaza lo que no es un importe', () {
      for (final value in [
        '',
        '   ',
        '€',
        '-5',
        '5-',
        '560,5055',
        ',50',
        '560,',
        '1.06.40',
        '1,062,40',
        '1.062,40.5',
        '1.062.40',
        'abc',
        '5e3',
        '1234567890',
      ]) {
        expect(parseEuroCents(value), isNull, reason: value);
      }
    });
  });

  test('formatCentsForInput: sin símbolo ni miles, decimales solo si hacen falta', () {
    expect(formatCentsForInput(56000, locale: 'it'), '560');
    expect(formatCentsForInput(56050, locale: 'es'), '560,50');
    expect(formatCentsForInput(56050, locale: 'en'), '560.50');
    expect(formatCentsForInput(106240, locale: 'it'), '1062,40');
    expect(formatCentsForInput(5, locale: 'it'), '0,05');
    // Lo que se escribe vuelve a leerse igual.
    for (final cents in [0, 5, 14000, 56050, 106240]) {
      for (final locale in ['it', 'es', 'en']) {
        expect(parseEuroCents(formatCentsForInput(cents, locale: locale)), cents);
      }
    }
  });
}

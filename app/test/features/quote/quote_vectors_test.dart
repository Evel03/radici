// La copia Dart del motor tiene que pasar los mismos vectores que quote.ts
// (supabase/functions/_shared/quote_vectors.json, SPEC.md §5.1).
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/features/quote/domain/quote.dart';

import '../../support/repo_files.dart';

const _vectorsPath = 'supabase/functions/_shared/quote_vectors.json';

/// Todos los campos del resultado, con los mismos nombres que en TS.
Map<String, int> _fieldsOf(Quote q) => {
  'adultPortions': q.adultPortions,
  'kidPortions': q.kidPortions,
  'portions': q.portions,
  'recipes': q.recipes,
  'cookMinutes': q.cookMinutes,
  'serviceCents': q.serviceCents,
  'groceriesEstCents': q.groceriesEstCents,
  'preauthCents': q.preauthCents,
  'holdCents': q.holdCents,
  'totalCents': q.totalCents,
};

List<Map<String, dynamic>> _objects(Object? list) =>
    (list! as List<dynamic>).cast<Map<String, dynamic>>();

void main() {
  final fixture = readJsonObject(findRepoFile(_vectorsPath));
  final defaultSettings = fixture['defaultSettings'] as Map<String, dynamic>;
  final vectors = _objects(fixture['vectors']);
  final invalid = _objects(fixture['invalid']);

  test('defaultPricing coincide con defaultSettings del fixture', () {
    expect(defaultPricing, PricingSettings.fromJson(defaultSettings));
    // Mismos nombres de campo que en TS, sin claves de más ni de menos.
    expect(defaultPricing.toJson(), defaultSettings);
  });

  test('el fixture tiene vectores e inválidos', () {
    expect(vectors, isNotEmpty);
    expect(invalid, isNotEmpty);
  });

  group('vectores', () {
    for (final v in vectors) {
      test('vector ${v['id']}: ${v['label']}', () {
        // Los `settings` del vector son parciales: se aplican sobre los
        // por defecto, como `{ ...defaultSettings, ...v.settings }` en TS.
        final settings = PricingSettings.fromJson({
          ...defaultSettings,
          ...?v['settings'] as Map<String, dynamic>?,
        });
        final input = QuoteInput.fromJson(v['input'] as Map<String, dynamic>);
        final actual = _fieldsOf(calcQuote(input, settings));
        final expected = v['expected'] as Map<String, dynamic>;

        expect(expected, isNotEmpty);
        for (final MapEntry(:key, :value) in expected.entries) {
          expect(
            actual.containsKey(key),
            isTrue,
            reason: 'campo desconocido: $key',
          );
          expect(actual[key], value, reason: key);
        }
      });
    }
  });

  group('entradas inválidas lanzan RangeError', () {
    for (final c in invalid) {
      test('${c['label']}', () {
        // Los decimales se rechazan al leer el JSON (StrictIntConverter);
        // el resto, en validateInput. Ambos lanzan RangeError, como en TS.
        expect(
          () => calcQuote(
            QuoteInput.fromJson(c['input'] as Map<String, dynamic>),
          ),
          throwsRangeError,
        );
      });
    }
  });

  group('tarifas inválidas lanzan RangeError', () {
    const input = QuoteInput(adults: 2, kids: 0, days: 1, meals: 1);
    final cases = <String, PricingSettings>{
      'tarifa negativa': defaultPricing.copyWith(hourlyRateCents: -1),
      'margen > 100 %': defaultPricing.copyWith(preauthBufferPct: 101),
      'mínimo de cocina > 24 h': defaultPricing.copyWith(minCookMinutes: 1441),
      'porción de adulto > 1000 €': defaultPricing.copyWith(
        adultPortionCents: 100001,
      ),
    };
    cases.forEach((label, settings) {
      test(label, () {
        expect(() => calcQuote(input, settings), throwsRangeError);
      });
    });
  });

  test('un decimal entero (2.0) se acepta, como Number.isInteger', () {
    final input = QuoteInput.fromJson(const {
      'adults': 2.0,
      'kids': 0,
      'days': 1,
      'meals': 1,
    });
    expect(input.adults, 2);
  });

  test('importes coherentes en todo el rango de entradas', () {
    // Mismo barrido que quote.test.ts. En Dart los campos ya son int; además
    // se verifican invariantes que valen para cualquier entrada.
    for (final hourlyRateCents in [2200, 2155, 1999, 2501]) {
      final settings = defaultPricing.copyWith(
        hourlyRateCents: hourlyRateCents,
      );
      for (var adults = 0; adults <= 12; adults++) {
        for (var kids = 0; kids <= 8; kids++) {
          if (adults + kids == 0) continue;
          for (var days = 1; days <= 7; days++) {
            for (var meals = 1; meals <= 2; meals++) {
              final q = calcQuote(
                QuoteInput(
                  adults: adults,
                  kids: kids,
                  days: days,
                  meals: meals,
                ),
                settings,
              );
              final label = '$hourlyRateCents/$adults/$kids/$days/$meals';
              expect(q.cookMinutes % 30, 0, reason: label);
              expect(q.recipes, inInclusiveRange(2, 6), reason: label);
              expect(
                q.preauthCents,
                greaterThanOrEqualTo(q.groceriesEstCents),
                reason: label,
              );
              expect(
                q.portions,
                q.adultPortions + q.kidPortions,
                reason: label,
              );
              expect(
                q.totalCents,
                q.serviceCents + q.groceriesEstCents,
                reason: label,
              );
              expect(
                _fieldsOf(q).values.every((v) => v >= 0),
                isTrue,
                reason: label,
              );
            }
          }
        }
      }
    }
  });
}

// La copia Dart del motor tiene que pasar los mismos vectores que quote.ts
// (supabase/functions/_shared/quote_vectors.json, SPEC.md §5.1).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/quote/domain/quote.dart';

import '../../support/repo_files.dart';

const _vectorsPath = 'supabase/functions/_shared/quote_vectors.json';

/// Lo que solo existe con precio automático (en TS, claves que no van).
const _priceKeys = [
  'weeklyServiceCents',
  'serviceCents',
  'savingsCents',
  'totalCents',
];

/// Todos los campos del resultado, con los mismos nombres y valores que en TS
/// (el motivo, como texto). Sin precio, los del precio quedan en null.
Map<String, Object?> _fieldsOf(Quote q) => {
  'weeks': q.weeks,
  'adultPortions': q.adultPortions,
  'kidPortions': q.kidPortions,
  'portions': q.portions,
  'recipes': q.recipes,
  'cookMinutes': q.cookMinutes,
  'groceriesEstCents': q.groceriesEstCents,
  'preauthCents': q.preauthCents,
  'autoPrice': q.autoPrice,
  'reason': q.reason?.name,
  'weeklyServiceCents': q.weeklyServiceCents,
  'serviceCents': q.serviceCents,
  'savingsCents': q.savingsCents,
  'totalCents': q.totalCents,
};

List<Map<String, dynamic>> _objects(Object? list) =>
    (list! as List<dynamic>).cast<Map<String, dynamic>>();

void main() {
  final fixture = readJsonObject(findRepoFile(_vectorsPath));
  final defaultSettings = fixture['defaultSettings'] as Map<String, dynamic>;
  final vectors = _objects(fixture['vectors']);
  final invalid = _objects(fixture['invalid']);
  final invalidSettings = _objects(fixture['invalidSettings']);
  final validSettings = _objects(fixture['validSettings']);

  test('defaultPricing coincide con defaultSettings del fixture', () {
    expect(defaultPricing, PricingSettings.fromJson(defaultSettings));
    // Mismos nombres de campo que en TS, sin claves de más ni de menos.
    expect(defaultPricing.toJson(), defaultSettings);
  });

  test('el fixture tiene vectores, entradas y tarifas inválidas y válidas', () {
    expect(vectors, isNotEmpty);
    expect(invalid, isNotEmpty);
    expect(invalidSettings, isNotEmpty);
    expect(validSettings, isNotEmpty);
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
        final quote = calcQuote(input, settings);
        final actual = _fieldsOf(quote);
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
        // Sin precio automático no hay precio (en TS, las claves no van).
        if (!quote.autoPrice) {
          for (final key in _priceKeys) {
            expect(actual[key], isNull, reason: key);
          }
        } else {
          expect(quote.reason, isNull);
        }
      });
    }
  });

  group('entradas inválidas lanzan RangeError', () {
    for (final c in invalid) {
      test('${c['label']}', () {
        // Los decimales y los tipos desconocidos se rechazan al leer el JSON
        // (StrictIntConverter, QuoteTypeConverter); el resto, en
        // validateInput. Todos lanzan RangeError, como en TS.
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
    const input = QuoteInput(
      type: QuoteType.week,
      adults: 2,
      kids: 0,
      days: 1,
      meals: 1,
      weeks: 1,
    );
    for (final c in invalidSettings) {
      test('${c['label']}', () {
        expect(
          () => calcQuote(
            input,
            PricingSettings.fromJson({
              ...defaultSettings,
              ...c['settings'] as Map<String, dynamic>,
            }),
          ),
          throwsRangeError,
        );
      });
    }
  });

  // El mínimo y el máximo de cada check de las columnas de chef_settings que
  // lee el motor (quote.test.ts compara la lista con las migraciones): cuando
  // la app calcule con las tarifas de la cocinera, ninguna fila que la base
  // guarda hace lanzar.
  group('tarifas válidas (los extremos de chef_settings) no lanzan', () {
    const inputs = [
      QuoteInput(
        type: QuoteType.week,
        adults: 2,
        kids: 2,
        days: 5,
        meals: 1,
        weeks: 4,
      ),
      QuoteInput(
        type: QuoteType.week,
        adults: 1,
        kids: 0,
        days: 1,
        meals: 1,
        weeks: 1,
      ),
      QuoteInput(
        type: QuoteType.week,
        adults: QuoteLimits.maxPeople,
        kids: QuoteLimits.maxPeople,
        days: QuoteLimits.maxDays,
        meals: QuoteLimits.maxMeals,
        weeks: QuoteLimits.maxWeeks,
      ),
      QuoteInput(
        type: QuoteType.extra,
        adults: 2,
        kids: 0,
        days: 1,
        meals: 1,
        weeks: 1,
      ),
    ];
    for (final c in validSettings) {
      test('${c['label']}', () {
        final settings = PricingSettings.fromJson({
          ...defaultSettings,
          ...c['settings'] as Map<String, dynamic>,
        });
        for (final input in inputs) {
          final quote = calcQuote(input, settings);
          expect(
            quote.autoPrice,
            input.type == QuoteType.week &&
                input.adults + input.kids <= settings.weeklyRateMaxPeople,
            reason: '$input',
          );
        }
      });
    }
  });

  test('un decimal entero (2.0) se acepta, como Number.isInteger', () {
    final input = QuoteInput.fromJson(const {
      'type': 'week',
      'adults': 2.0,
      'kids': 0,
      'days': 1,
      'meals': 1,
      'weeks': 4.0,
    });
    expect(input.adults, 2);
    expect(input.weeks, 4);
  });

  test('importes coherentes en todo el rango de entradas', () {
    // Mismo barrido que quote.test.ts. En Dart los campos ya son int; además
    // se verifican invariantes que valen para cualquier entrada.
    final settingsList = [
      defaultPricing,
      defaultPricing.copyWith(
        weeklyRateCents: 16000,
        weeklyRateDiscountedCents: 15000,
        weeklyDiscountMinWeeks: 3,
        weeklyRateMaxPeople: 6,
      ),
      defaultPricing.copyWith(
        weeklyRateCents: 14999,
        weeklyRateDiscountedCents: 13333,
        weeklyDiscountMinWeeks: 1,
        weeklyRateMaxPeople: 60,
      ),
    ];
    for (final settings in settingsList) {
      for (var adults = 0; adults <= 8; adults++) {
        for (var kids = 0; kids <= 6; kids++) {
          if (adults + kids == 0) continue;
          for (var days = 1; days <= 7; days++) {
            for (var meals = 1; meals <= 2; meals++) {
              for (var weeks = 1; weeks <= QuoteLimits.maxWeeks; weeks++) {
                final q = calcQuote(
                  QuoteInput(
                    type: QuoteType.week,
                    adults: adults,
                    kids: kids,
                    days: days,
                    meals: meals,
                    weeks: weeks,
                  ),
                  settings,
                );
                final label = '$adults/$kids/$days/$meals/$weeks';
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
                  q.autoPrice,
                  adults + kids <= settings.weeklyRateMaxPeople,
                  reason: label,
                );
                if (q.autoPrice) {
                  expect(
                    q.serviceCents,
                    q.weeklyServiceCents! * weeks,
                    reason: label,
                  );
                  expect(
                    q.totalCents,
                    q.serviceCents! + q.groceriesEstCents * weeks,
                    reason: label,
                  );
                }
                expect(
                  _fieldsOf(
                    q,
                  ).values.whereType<int>().every((value) => value >= 0),
                  isTrue,
                  reason: label,
                );
              }
            }
          }
        }
      }
    }
  });
}

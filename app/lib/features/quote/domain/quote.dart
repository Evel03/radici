// Motor de presupuesto (SPEC.md §5.1): copia en Dart de
// supabase/functions/_shared/quote.ts, que es la fuente única de verdad.
// La app lo usa solo para la vista previa; el importe que vale lo calcula el
// servidor. Tiene que pasar los mismos vectores (quote_vectors.json).
//
// Solo aritmética entera (`int`, `~/`): ningún paso usa decimales.
// Dart puro: sin Flutter, para poder testearlo y reutilizarlo en cualquier capa.
import 'dart:math' as math;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'quote.freezed.dart';
part 'quote.g.dart';

/// Tarifas de la cocinera. Montos en centavos.
@freezed
abstract class PricingSettings with _$PricingSettings {
  @JsonSerializable(converters: [StrictIntConverter()])
  const factory PricingSettings({
    required int hourlyRateCents,
    required int travelFeeCents,
    required int adultPortionCents,
    required int kidPortionCents,
    required int preauthBufferPct,
    required int minCookMinutes,
  }) = _PricingSettings;

  factory PricingSettings.fromJson(Map<String, dynamic> json) =>
      _$PricingSettingsFromJson(json);
}

/// Entrada del presupuesto.
@freezed
abstract class QuoteInput with _$QuoteInput {
  @JsonSerializable(converters: [StrictIntConverter()])
  const factory QuoteInput({
    required int adults,
    required int kids,
    required int days,

    /// Comidas por día: 1 (almuerzo o cena) o 2 (almuerzo y cena).
    required int meals,
  }) = _QuoteInput;

  factory QuoteInput.fromJson(Map<String, dynamic> json) =>
      _$QuoteInputFromJson(json);
}

/// Resultado del presupuesto. Montos en centavos, tiempos en minutos.
@freezed
abstract class Quote with _$Quote {
  const factory Quote({
    required int adultPortions,
    required int kidPortions,
    required int portions,
    required int recipes,
    required int cookMinutes,
    required int serviceCents,
    required int groceriesEstCents,
    required int preauthCents,

    /// Máximo retenido en la tarjeta con pre-autorización única (§5.4):
    /// servicio + [preauthCents].
    required int holdCents,
    required int totalCents,
  }) = _Quote;
}

/// Equivalente a `DEFAULT_PRICING` de quote.ts.
const PricingSettings defaultPricing = PricingSettings(
  hourlyRateCents: 2200,
  travelFeeCents: 1200,
  adultPortionCents: 380,
  kidPortionCents: 250,
  preauthBufferPct: 15,
  minCookMinutes: 90,
);

/// Equivalente a `LIMITS` de quote.ts.
abstract final class QuoteLimits {
  static const int maxPeople = 30;
  static const int maxDays = 7;
  static const int maxMeals = 2;
  static const int minRecipes = 2;
  static const int maxRecipes = 6;
}

/// Lee un número JSON como `int` sin perder información.
///
/// En TS los números no distinguen int de double y `calcQuote` rechaza los
/// decimales con `Number.isInteger`. En Dart los campos son `int`, así que
/// esa validación se hace al leer el JSON: un decimal lanza [RangeError]
/// (igual que quote.ts) en lugar de truncarse en silencio.
class StrictIntConverter implements JsonConverter<int, num> {
  const StrictIntConverter();

  @override
  int fromJson(num json) {
    if (json is int) return json;
    // 2.0 es entero para Number.isInteger: se acepta.
    if (json.isFinite && json == json.truncateToDouble()) return json.toInt();
    throw RangeError.value(json, null, 'Tiene que ser un número entero');
  }

  @override
  num toJson(int object) => object;
}

/// División entera hacia arriba para enteros no negativos.
int _divUp(int a, int b) => (a + b - 1) ~/ b;

void _assertInt(String name, int value, int min, int max) {
  if (value < min || value > max) {
    throw RangeError.range(
      value,
      min,
      max,
      name,
      '$name debe ser un entero entre $min y $max (recibido: $value)',
    );
  }
}

/// Valida la entrada. Lanza [RangeError] si no es válida.
void validateInput(QuoteInput input) {
  _assertInt('adults', input.adults, 0, QuoteLimits.maxPeople);
  _assertInt('kids', input.kids, 0, QuoteLimits.maxPeople);
  _assertInt('days', input.days, 1, QuoteLimits.maxDays);
  _assertInt('meals', input.meals, 1, QuoteLimits.maxMeals);
  if (input.adults + input.kids < 1) {
    throw RangeError('Tiene que haber al menos una persona');
  }
}

void _validateSettings(PricingSettings s) {
  _assertInt('hourlyRateCents', s.hourlyRateCents, 0, 1000000);
  _assertInt('travelFeeCents', s.travelFeeCents, 0, 1000000);
  _assertInt('adultPortionCents', s.adultPortionCents, 0, 100000);
  _assertInt('kidPortionCents', s.kidPortionCents, 0, 100000);
  _assertInt('preauthBufferPct', s.preauthBufferPct, 0, 100);
  _assertInt('minCookMinutes', s.minCookMinutes, 0, 24 * 60);
}

/// Calcula el presupuesto. Lanza [RangeError] si la entrada o las tarifas
/// no son válidas.
Quote calcQuote(QuoteInput input, [PricingSettings settings = defaultPricing]) {
  validateInput(input);
  _validateSettings(settings);

  final adultPortions = input.adults * input.days * input.meals;
  final kidPortions = input.kids * input.days * input.meals;
  final portions = adultPortions + kidPortions;

  final recipes = math.min(
    QuoteLimits.maxRecipes,
    math.max(
      QuoteLimits.minRecipes,
      math.min(_divUp(input.days * input.meals, 2), portions ~/ 2),
    ),
  );

  // ceil_a_30(60 + 30·recetas + 1,2·porciones), multiplicado por 5 para
  // quedar en enteros.
  final cookMinutes = math.max(
    settings.minCookMinutes,
    _divUp(300 + 150 * recipes + 6 * portions, 150) * 30,
  );

  // Redondeo al centavo, mitad hacia arriba.
  final serviceCents =
      (cookMinutes * settings.hourlyRateCents + 30) ~/ 60 +
      settings.travelFeeCents;
  final groceriesEstCents =
      adultPortions * settings.adultPortionCents +
      kidPortions * settings.kidPortionCents;
  final preauthCents = _divUp(
    groceriesEstCents * (100 + settings.preauthBufferPct),
    100,
  );

  return Quote(
    adultPortions: adultPortions,
    kidPortions: kidPortions,
    portions: portions,
    recipes: recipes,
    cookMinutes: cookMinutes,
    serviceCents: serviceCents,
    groceriesEstCents: groceriesEstCents,
    preauthCents: preauthCents,
    holdCents: serviceCents + preauthCents,
    totalCents: serviceCents + groceriesEstCents,
  );
}

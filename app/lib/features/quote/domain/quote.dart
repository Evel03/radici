// Motor de presupuesto (SPEC.md §5.1): copia en Dart de
// supabase/functions/_shared/quote.ts, que es la fuente única de verdad.
// La app lo usa solo para la vista previa; el importe que vale lo calcula el
// servidor. Tiene que pasar los mismos vectores (quote_vectors.json).
//
// Precio por semana (decisiones del dueño del 15 y 16/11/2026): de 1 a 8
// semanas, un menú y una sesión de cocina por semana. El servicio cuesta lo
// mismo cada semana para un hogar de hasta `weeklyRateMaxPeople` personas,
// sin importar días ni comidas; desde `weeklyDiscountMinWeeks` semanas, la
// tarifa con descuento. Con más personas, o en una sesión extra, no hay precio
// automático. La compra va aparte: el motor da una estimación por semana.
//
// Solo aritmética entera (`int`, `~/`): ningún paso usa decimales.
// Dart puro: sin Flutter, para poder testearlo y reutilizarlo en cualquier capa.
import 'dart:math' as math;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'quote.freezed.dart';
part 'quote.g.dart';

/// Tarifas de la cocinera (`chef_settings`). Montos en centavos.
@freezed
abstract class PricingSettings with _$PricingSettings {
  @JsonSerializable(converters: [StrictIntConverter()])
  const factory PricingSettings({
    /// Servicio de una semana, traslado incluido.
    required int weeklyRateCents,

    /// Servicio de cada semana desde [weeklyDiscountMinWeeks] semanas.
    required int weeklyRateDiscountedCents,
    required int weeklyDiscountMinWeeks,

    /// Hasta cuántas personas (adultos y niños) hay precio automático.
    required int weeklyRateMaxPeople,
    required int adultPortionCents,
    required int kidPortionCents,
    required int preauthBufferPct,
    required int minCookMinutes,
  }) = _PricingSettings;

  factory PricingSettings.fromJson(Map<String, dynamic> json) =>
      _$PricingSettingsFromJson(json);
}

/// `week`: semana de comidas (precio por semana); `extra`: sesión extra suelta
/// (sin precio automático). Como `QuoteType` de quote.ts.
enum QuoteType { week, extra }

/// Lee el tipo del JSON como quote.ts: uno desconocido (`change`) lanza
/// [RangeError], no el `ArgumentError` de json_serializable.
class QuoteTypeConverter implements JsonConverter<QuoteType, String> {
  const QuoteTypeConverter();

  @override
  QuoteType fromJson(String json) => QuoteType.values.firstWhere(
    (type) => type.name == json,
    orElse: () =>
        throw RangeError('type tiene que ser week o extra (recibido: $json)'),
  );

  @override
  String toJson(QuoteType object) => object.name;
}

/// Entrada del presupuesto.
@freezed
abstract class QuoteInput with _$QuoteInput {
  @JsonSerializable(converters: [StrictIntConverter(), QuoteTypeConverter()])
  const factory QuoteInput({
    required QuoteType type,
    required int adults,
    required int kids,

    /// Días de comidas de cada semana.
    required int days,

    /// Comidas por día: 1 (almuerzo o cena) o 2 (almuerzo y cena).
    required int meals,

    /// Semanas del pedido semanal (1 a 8). Una sesión extra siempre es de 1.
    required int weeks,
  }) = _QuoteInput;

  factory QuoteInput.fromJson(Map<String, dynamic> json) =>
      _$QuoteInputFromJson(json);
}

/// Por qué no hay precio automático: más personas que `weeklyRateMaxPeople`,
/// o una sesión extra. Mismos valores que `NoAutoPriceReason` de quote.ts.
enum NoAutoPriceReason { people, extra }

/// Resultado del presupuesto. Montos en centavos, tiempos en minutos.
///
/// Porciones, recetas, minutos y compra son de una semana (una sesión). Sin
/// precio automático ([autoPrice] false) los campos del precio quedan en null
/// y [reason] dice por qué; con precio, [reason] es null.
@freezed
abstract class Quote with _$Quote {
  const factory Quote({
    required int weeks,
    required int adultPortions,
    required int kidPortions,
    required int portions,
    required int recipes,
    required int cookMinutes,

    /// Compra estimada de una semana: se paga aparte, al costo del ticket.
    required int groceriesEstCents,

    /// Pre-autorización de la compra de una semana (§5.4).
    required int preauthCents,
    required bool autoPrice,
    NoAutoPriceReason? reason,

    /// Servicio de cada semana (la tarifa o la de descuento).
    int? weeklyServiceCents,

    /// Servicio de todas las semanas.
    int? serviceCents,

    /// Ahorro frente a la tarifa sin descuento.
    int? savingsCents,

    /// Servicio y compra estimada de todas las semanas.
    int? totalCents,
  }) = _Quote;
}

/// Equivalente a `DEFAULT_PRICING` de quote.ts (los valores por defecto de
/// `chef_settings`).
const PricingSettings defaultPricing = PricingSettings(
  weeklyRateCents: 15000,
  weeklyRateDiscountedCents: 14000,
  weeklyDiscountMinWeeks: 4,
  weeklyRateMaxPeople: 5,
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
  static const int maxWeeks = 8;
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
  _assertInt(
    'weeks',
    input.weeks,
    1,
    input.type == QuoteType.week ? QuoteLimits.maxWeeks : 1,
  );
  if (input.adults + input.kids < 1) {
    throw RangeError('Tiene que haber al menos una persona');
  }
}

/// Los rangos incluyen los checks de `chef_settings`.
void _validateSettings(PricingSettings s) {
  _assertInt('weeklyRateCents', s.weeklyRateCents, 0, 1000000);
  _assertInt(
    'weeklyRateDiscountedCents',
    s.weeklyRateDiscountedCents,
    0,
    s.weeklyRateCents,
  );
  _assertInt(
    'weeklyDiscountMinWeeks',
    s.weeklyDiscountMinWeeks,
    1,
    QuoteLimits.maxWeeks,
  );
  _assertInt(
    'weeklyRateMaxPeople',
    s.weeklyRateMaxPeople,
    1,
    2 * QuoteLimits.maxPeople,
  );
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

  // Una semana: los días y las comidas de cada sesión.
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

  final groceriesEstCents =
      adultPortions * settings.adultPortionCents +
      kidPortions * settings.kidPortionCents;
  final preauthCents = _divUp(
    groceriesEstCents * (100 + settings.preauthBufferPct),
    100,
  );

  final NoAutoPriceReason? reason;
  if (input.type == QuoteType.extra) {
    reason = NoAutoPriceReason.extra;
  } else if (input.adults + input.kids > settings.weeklyRateMaxPeople) {
    reason = NoAutoPriceReason.people;
  } else {
    reason = null;
  }

  Quote unpriced(NoAutoPriceReason why) => Quote(
    weeks: input.weeks,
    adultPortions: adultPortions,
    kidPortions: kidPortions,
    portions: portions,
    recipes: recipes,
    cookMinutes: cookMinutes,
    groceriesEstCents: groceriesEstCents,
    preauthCents: preauthCents,
    autoPrice: false,
    reason: why,
  );
  if (reason != null) return unpriced(reason);

  final weeklyServiceCents = input.weeks >= settings.weeklyDiscountMinWeeks
      ? settings.weeklyRateDiscountedCents
      : settings.weeklyRateCents;
  final serviceCents = weeklyServiceCents * input.weeks;
  return Quote(
    weeks: input.weeks,
    adultPortions: adultPortions,
    kidPortions: kidPortions,
    portions: portions,
    recipes: recipes,
    cookMinutes: cookMinutes,
    groceriesEstCents: groceriesEstCents,
    preauthCents: preauthCents,
    autoPrice: true,
    weeklyServiceCents: weeklyServiceCents,
    serviceCents: serviceCents,
    savingsCents: settings.weeklyRateCents * input.weeks - serviceCents,
    totalCents: serviceCents + groceriesEstCents * input.weeks,
  );
}

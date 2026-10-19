// Estado editable de la calculadora. Vive en la capa de aplicación porque
// distingue pranzo de cena, algo que el motor no necesita (solo cuenta comidas
// por día) pero el pedido sí (`requests.meals text[]`, SPEC.md §4).
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/features/quote/domain/quote.dart';

part 'quote_draft.freezed.dart';

/// Qué comidas del día cocina Evelyn.
enum MealPlan {
  lunch(1),
  dinner(1),
  lunchAndDinner(2);

  const MealPlan(this.mealsPerDay);

  /// Valor de `QuoteInput.meals`.
  final int mealsPerDay;
}

/// Contadores que el cliente ajusta con + y −.
enum QuoteCounter { adults, kids, days }

/// Borrador del pedido mientras el cliente lo arma.
///
/// Las reglas de límites viven acá (no en los widgets), así los botones
/// se deshabilitan exactamente cuando el motor rechazaría el valor.
@freezed
abstract class QuoteDraft with _$QuoteDraft {
  const factory QuoteDraft({
    required int adults,
    required int kids,
    required int days,
    required MealPlan mealPlan,
  }) = _QuoteDraft;

  const QuoteDraft._();

  /// Entrada inicial: el caso típico (vector 1 de SPEC.md §5.1).
  static const QuoteDraft initial = QuoteDraft(
    adults: 2,
    kids: 2,
    days: 5,
    mealPlan: MealPlan.dinner,
  );

  QuoteInput toInput() => QuoteInput(
    adults: adults,
    kids: kids,
    days: days,
    meals: mealPlan.mealsPerDay,
  );

  int valueOf(QuoteCounter counter) => switch (counter) {
    QuoteCounter.adults => adults,
    QuoteCounter.kids => kids,
    QuoteCounter.days => days,
  };

  bool canIncrement(QuoteCounter counter) => switch (counter) {
    QuoteCounter.adults => adults < QuoteLimits.maxPeople,
    QuoteCounter.kids => kids < QuoteLimits.maxPeople,
    QuoteCounter.days => days < QuoteLimits.maxDays,
  };

  /// Tiene que quedar al menos una persona (adultos + niños ≥ 1).
  bool canDecrement(QuoteCounter counter) => switch (counter) {
    QuoteCounter.adults => adults > 0 && adults + kids > 1,
    QuoteCounter.kids => kids > 0 && adults + kids > 1,
    QuoteCounter.days => days > 1,
  };

  QuoteDraft withValue(QuoteCounter counter, int value) => switch (counter) {
    QuoteCounter.adults => copyWith(adults: value),
    QuoteCounter.kids => copyWith(kids: value),
    QuoteCounter.days => copyWith(days: value),
  };
}

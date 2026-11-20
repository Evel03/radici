// Estado de la calculadora: límites del notifier y resultado derivado.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/quote/application/quote_draft.dart';
import 'package:radici/features/quote/application/quote_providers.dart';
import 'package:radici/features/quote/domain/quote.dart';

void main() {
  late ProviderContainer container;
  QuoteDraft draft() => container.read(quoteInputProvider);
  QuoteInputNotifier notifier() => container.read(quoteInputProvider.notifier);
  Quote quote() => container.read(quoteProvider);

  setUp(() => container = ProviderContainer.test());

  test('arranca con la entrada inicial y su presupuesto (vector 1)', () {
    expect(draft(), QuoteDraft.initial);
    expect(draft().toInput().type, QuoteType.week);
    expect(quote().weeks, 1);
    expect(quote().serviceCents, 15000);
    expect(quote().portions, 20);
  });

  test('pranzo y cena cuentan una comida; ambos, dos', () {
    expect(MealPlan.lunch.mealsPerDay, 1);
    expect(MealPlan.dinner.mealsPerDay, 1);
    expect(MealPlan.lunchAndDinner.mealsPerDay, 2);

    notifier().selectMealPlan(MealPlan.lunchAndDinner);
    expect(draft().toInput().meals, 2);
    // Como el vector 12 (de una semana): las porciones se duplican, el
    // servicio por semana no.
    expect(quote().portions, 40);
    expect(quote().serviceCents, 15000);
  });

  test('las semanas: desde 4, la tarifa con descuento (vector 3)', () {
    for (var i = 0; i < 3; i++) {
      notifier().increment(QuoteCounter.weeks);
    }
    expect(draft().weeks, 4);
    expect(quote().weeklyServiceCents, 14000);
    expect(quote().serviceCents, 56000);
    expect(quote().savingsCents, 4000);
  });

  test('los contadores no pasan los límites del motor', () {
    for (var i = 0; i < 40; i++) {
      notifier()
        ..increment(QuoteCounter.adults)
        ..increment(QuoteCounter.kids)
        ..increment(QuoteCounter.days)
        ..increment(QuoteCounter.weeks);
    }
    expect(draft().adults, QuoteLimits.maxPeople);
    expect(draft().kids, QuoteLimits.maxPeople);
    expect(draft().days, QuoteLimits.maxDays);
    expect(draft().weeks, QuoteLimits.maxWeeks);
    expect(draft().canIncrement(QuoteCounter.adults), isFalse);
    expect(draft().canIncrement(QuoteCounter.weeks), isFalse);

    for (var i = 0; i < 40; i++) {
      notifier()
        ..decrement(QuoteCounter.days)
        ..decrement(QuoteCounter.weeks);
    }
    expect(draft().days, 1);
    expect(draft().weeks, 1);
    expect(draft().canDecrement(QuoteCounter.days), isFalse);
    expect(draft().canDecrement(QuoteCounter.weeks), isFalse);
  });

  test('siempre queda al menos una persona', () {
    for (var i = 0; i < 40; i++) {
      notifier()
        ..decrement(QuoteCounter.adults)
        ..decrement(QuoteCounter.kids);
    }
    expect(draft().adults + draft().kids, 1);
    expect(draft().canDecrement(QuoteCounter.adults), isFalse);
    expect(draft().canDecrement(QuoteCounter.kids), isFalse);
    // El presupuesto sigue siendo calculable.
    expect(() => container.read(quoteProvider), returnsNormally);
  });

  test('con más de 5 personas no hay precio automático', () {
    notifier()
      ..increment(QuoteCounter.adults)
      ..increment(QuoteCounter.kids);
    expect(draft().adults + draft().kids, 6);
    expect(quote().autoPrice, isFalse);
    expect(quote().reason, NoAutoPriceReason.people);
    expect(quote().serviceCents, isNull);
  });

  test('el presupuesto usa las tarifas del provider', () {
    // Las de Giulia en el seed: 160 €, 150 € desde 3 semanas, hasta 6 personas.
    final custom = ProviderContainer.test(
      overrides: [
        pricingSettingsProvider.overrideWithValue(
          defaultPricing.copyWith(
            weeklyRateCents: 16000,
            weeklyRateDiscountedCents: 15000,
            weeklyDiscountMinWeeks: 3,
            weeklyRateMaxPeople: 6,
          ),
        ),
      ],
    );
    expect(custom.read(quoteProvider).serviceCents, 16000);
    custom.read(quoteInputProvider.notifier)
      ..increment(QuoteCounter.weeks)
      ..increment(QuoteCounter.weeks)
      ..increment(QuoteCounter.adults)
      ..increment(QuoteCounter.kids);
    // Vector 16 (con otras personas): 6 personas y 3 semanas.
    expect(custom.read(quoteProvider).weeklyServiceCents, 15000);
    expect(custom.read(quoteProvider).serviceCents, 45000);
    expect(custom.read(quoteProvider).savingsCents, 3000);
  });
}

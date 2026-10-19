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

  setUp(() => container = ProviderContainer.test());

  test('arranca con la entrada inicial y su presupuesto (vector 1)', () {
    expect(draft(), QuoteDraft.initial);
    expect(container.read(quoteProvider).totalCents, 14100);
  });

  test('pranzo y cena cuentan una comida; ambos, dos', () {
    expect(MealPlan.lunch.mealsPerDay, 1);
    expect(MealPlan.dinner.mealsPerDay, 1);
    expect(MealPlan.lunchAndDinner.mealsPerDay, 2);

    notifier().selectMealPlan(MealPlan.lunchAndDinner);
    expect(draft().toInput().meals, 2);
    // Vector 6: 2 ad · 2 niños · 5 días · almuerzo y cena.
    expect(container.read(quoteProvider).totalCents, 23700);
  });

  test('los contadores no pasan los límites del motor', () {
    for (var i = 0; i < 40; i++) {
      notifier()
        ..increment(QuoteCounter.adults)
        ..increment(QuoteCounter.kids)
        ..increment(QuoteCounter.days);
    }
    expect(draft().adults, QuoteLimits.maxPeople);
    expect(draft().kids, QuoteLimits.maxPeople);
    expect(draft().days, QuoteLimits.maxDays);
    expect(draft().canIncrement(QuoteCounter.adults), isFalse);

    for (var i = 0; i < 40; i++) {
      notifier().decrement(QuoteCounter.days);
    }
    expect(draft().days, 1);
    expect(draft().canDecrement(QuoteCounter.days), isFalse);
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

  test('el presupuesto usa las tarifas del provider', () {
    final custom = ProviderContainer.test(
      overrides: [
        pricingSettingsProvider.overrideWithValue(
          defaultPricing.copyWith(hourlyRateCents: 2155),
        ),
      ],
    );
    custom.read(quoteInputProvider.notifier)
      ..decrement(QuoteCounter.adults)
      ..decrement(QuoteCounter.kids)
      ..decrement(QuoteCounter.kids)
      ..selectMealPlan(MealPlan.lunch);
    // Vector 9: 1 ad · 5 días · almuerzo con 21,55 €/h.
    expect(custom.read(quoteProvider).serviceCents, 6588);
    expect(custom.read(quoteProvider).totalCents, 8488);
  });
}

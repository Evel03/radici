// Providers de la calculadora de presupuesto. Los widgets solo leen estos
// providers y llaman a los métodos del notifier: no calculan nada.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/quote/application/quote_draft.dart';
import 'package:radici/features/quote/domain/quote.dart';

/// Tarifas vigentes. En M0 son las por defecto; desde M2/M3 se leerán de
/// `chef_settings` en Supabase (a través de un repositorio).
final pricingSettingsProvider = Provider<PricingSettings>(
  (ref) => defaultPricing,
);

/// Entrada de la calculadora, editable por el cliente.
final quoteInputProvider = NotifierProvider<QuoteInputNotifier, QuoteDraft>(
  QuoteInputNotifier.new,
);

/// Presupuesto estimado, derivado de la entrada y las tarifas.
final quoteProvider = Provider<Quote>(
  (ref) => calcQuote(
    ref.watch(quoteInputProvider).toInput(),
    ref.watch(pricingSettingsProvider),
  ),
);

class QuoteInputNotifier extends Notifier<QuoteDraft> {
  @override
  QuoteDraft build() => QuoteDraft.initial;

  /// Suma uno al contador si no está en el máximo.
  void increment(QuoteCounter counter) {
    if (!state.canIncrement(counter)) return;
    state = state.withValue(counter, state.valueOf(counter) + 1);
  }

  /// Resta uno al contador si no está en el mínimo.
  void decrement(QuoteCounter counter) {
    if (!state.canDecrement(counter)) return;
    state = state.withValue(counter, state.valueOf(counter) - 1);
  }

  void selectMealPlan(MealPlan mealPlan) {
    state = state.copyWith(mealPlan: mealPlan);
  }
}

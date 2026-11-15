// Calculadora de presupuesto: vista previa de la pantalla "Pedir" (SPEC.md §7).
// Solo muestra lo que dan los providers; el cálculo vive en el motor.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/money.dart';
import 'package:radici/features/quote/application/quote_draft.dart';
import 'package:radici/features/quote/application/quote_providers.dart';
import 'package:radici/l10n/app_localizations.dart';

class QuoteCalculatorScreen extends StatelessWidget {
  const QuoteCalculatorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.quoteTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _SectionHeader(l10n.quotePeopleSection),
                _CounterRow(
                  counter: QuoteCounter.adults,
                  label: l10n.quoteAdults,
                ),
                _CounterRow(counter: QuoteCounter.kids, label: l10n.quoteKids),
                const SizedBox(height: 8),
                _CounterRow(counter: QuoteCounter.days, label: l10n.quoteDays),
                const SizedBox(height: 8),
                _SectionHeader(l10n.quoteMealsSection),
                const _MealPlanSelector(),
                const SizedBox(height: 24),
                const _QuoteBreakdown(),
                const SizedBox(height: 12),
                Text(
                  l10n.quoteFootnote,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Fila con etiqueta, botón −, valor y botón +.
class _CounterRow extends ConsumerWidget {
  const _CounterRow({required this.counter, required this.label});

  final QuoteCounter counter;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final draft = ref.watch(quoteInputProvider);
    final notifier = ref.read(quoteInputProvider.notifier);
    final value = draft.valueOf(counter);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            // El lector de pantalla lee "Adulti, 2" en un solo nodo.
            child: Semantics(
              value: '$value',
              child: Text(label, style: textTheme.titleMedium),
            ),
          ),
          IconButton.filledTonal(
            key: ValueKey('quote-${counter.name}-decrement'),
            tooltip: l10n.counterDecrease(label),
            onPressed: draft.canDecrement(counter)
                ? () => notifier.decrement(counter)
                : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 48,
            child: ExcludeSemantics(
              child: Text(
                '$value',
                key: ValueKey('quote-${counter.name}-value'),
                textAlign: TextAlign.center,
                style: textTheme.titleLarge,
              ),
            ),
          ),
          IconButton.filledTonal(
            key: ValueKey('quote-${counter.name}-increment'),
            tooltip: l10n.counterIncrease(label),
            onPressed: draft.canIncrement(counter)
                ? () => notifier.increment(counter)
                : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _MealPlanSelector extends ConsumerWidget {
  const _MealPlanSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final mealPlan = ref.watch(quoteInputProvider.select((d) => d.mealPlan));

    String labelOf(MealPlan plan) => switch (plan) {
      MealPlan.lunch => l10n.mealLunch,
      MealPlan.dinner => l10n.mealDinner,
      MealPlan.lunchAndDinner => l10n.mealLunchAndDinner,
    };

    return SegmentedButton<MealPlan>(
      key: const ValueKey('quote-meal-plan'),
      showSelectedIcon: false,
      segments: [
        for (final plan in MealPlan.values)
          ButtonSegment(
            value: plan,
            label: Text(
              labelOf(plan),
              key: ValueKey('quote-meal-${plan.name}'),
              textAlign: TextAlign.center,
            ),
          ),
      ],
      selected: {mealPlan},
      onSelectionChanged: (selection) => ref
          .read(quoteInputProvider.notifier)
          .selectMealPlan(selection.single),
    );
  }
}

/// Desglose en vivo del presupuesto. Sin tiempo de cocina, como en la web: el
/// motor lo usa para el precio, pero el cliente no lo ve.
class _QuoteBreakdown extends ConsumerWidget {
  const _QuoteBreakdown();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final quote = ref.watch(quoteProvider);
    final locale = Localizations.localeOf(context).toString();
    String money(int cents) => formatCents(cents, locale: locale);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(l10n.quoteBreakdownSection),
            _BreakdownRow(
              label: l10n.quotePortions,
              value: '${quote.portions}',
              valueKey: const ValueKey('quote-portions'),
            ),
            _BreakdownRow(
              label: l10n.quoteRecipes,
              value: '${quote.recipes}',
              valueKey: const ValueKey('quote-recipes'),
            ),
            const Divider(height: 24),
            _BreakdownRow(
              label: l10n.quoteService,
              value: money(quote.serviceCents),
              valueKey: const ValueKey('quote-service'),
            ),
            _BreakdownRow(
              label: l10n.quoteGroceries,
              value: money(quote.groceriesEstCents),
              valueKey: const ValueKey('quote-groceries'),
            ),
            _BreakdownRow(
              label: l10n.quoteHold,
              value: money(quote.holdCents),
              valueKey: const ValueKey('quote-hold'),
            ),
            const Divider(height: 24),
            // liveRegion: el lector de pantalla anuncia el total al cambiar.
            Semantics(
              liveRegion: true,
              child: _BreakdownRow(
                label: l10n.quoteTotal,
                value: money(quote.totalCents),
                valueKey: const ValueKey('quote-total'),
                emphasized: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.label,
    required this.value,
    required this.valueKey,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final Key valueKey;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = emphasized ? textTheme.titleMedium : textTheme.bodyLarge;
    final valueStyle = emphasized
        ? textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)
        : textTheme.bodyLarge;

    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(child: Text(label, style: labelStyle)),
            const SizedBox(width: 16),
            Text(value, key: valueKey, style: valueStyle),
          ],
        ),
      ),
    );
  }
}

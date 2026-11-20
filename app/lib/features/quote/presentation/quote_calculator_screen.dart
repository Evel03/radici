// Calculadora de presupuesto: vista previa de la pantalla "Pedir" (SPEC.md §7).
// Solo muestra lo que dan los providers; el cálculo vive en el motor.
// Precio por semana (SPEC §5.1): el servicio de todas las semanas, el de cada
// semana y el ahorro desde el descuento; con más personas que el tope, que el
// precio lo prepara Evelyn. Sin compra: la hace el cliente, con la lista que
// le manda Evelyn.
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
                _CounterRow(
                  counter: QuoteCounter.weeks,
                  label: l10n.quoteWeeks,
                ),
                _CounterRow(
                  counter: QuoteCounter.days,
                  label: l10n.quoteDaysPerWeek,
                ),
                const SizedBox(height: 8),
                _SectionHeader(l10n.quoteMealsSection),
                const _MealPlanSelector(),
                const SizedBox(height: 24),
                const _QuoteBreakdown(),
                const SizedBox(height: 12),
                const _Footnote(),
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
/// motor lo usa para los horarios, pero el cliente no lo ve.
class _QuoteBreakdown extends ConsumerWidget {
  const _QuoteBreakdown();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final quote = ref.watch(quoteProvider);
    final pricing = ref.watch(pricingSettingsProvider);
    final locale = Localizations.localeOf(context).toString();
    String money(int cents) => formatCents(cents, locale: locale);
    final serviceCents = quote.serviceCents;
    final weeklyServiceCents = quote.weeklyServiceCents;
    final savingsCents = quote.savingsCents ?? 0;

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
            if (serviceCents == null)
              // Sin precio automático (más personas que el tope): lo prepara
              // Evelyn. liveRegion: el lector de pantalla lo anuncia al cambiar.
              Semantics(
                liveRegion: true,
                child: Text(
                  l10n.quoteNoAutoPrice(pricing.weeklyRateMaxPeople),
                  key: const ValueKey('quote-no-auto-price'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              )
            else ...[
              if (quote.weeks > 1 && weeklyServiceCents != null)
                _BreakdownRow(
                  label: l10n.quoteWeeklyService,
                  value: money(weeklyServiceCents),
                  valueKey: const ValueKey('quote-weekly'),
                ),
              if (savingsCents > 0)
                _BreakdownRow(
                  label: l10n.quoteSavings,
                  value: money(savingsCents),
                  valueKey: const ValueKey('quote-savings'),
                ),
              // liveRegion: el lector de pantalla anuncia el total al cambiar.
              Semantics(
                liveRegion: true,
                child: _BreakdownRow(
                  label: l10n.quoteServiceTotal(quote.weeks),
                  value: money(serviceCents),
                  valueKey: const ValueKey('quote-total'),
                  emphasized: true,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Nota bajo el desglose, con los números de las tarifas.
class _Footnote extends ConsumerWidget {
  const _Footnote();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final pricing = ref.watch(pricingSettingsProvider);
    final locale = Localizations.localeOf(context).toString();
    final theme = Theme.of(context);
    return Text(
      l10n.quoteFootnote(
        pricing.weeklyRateMaxPeople,
        pricing.weeklyDiscountMinWeeks,
        formatCents(pricing.weeklyRateDiscountedCents, locale: locale),
      ),
      key: const ValueKey('quote-footnote'),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
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

// Diálogo de un rango de días: resumen ("17 giorni · 13 in cui lavori · 3 già
// bloccati"), nota con letra de 16 px o más y las tres salidas.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/presentation/block_range_dialog.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/text_input_guard.dart';

void main() {
  final first = CalendarDate(2026, 12, 21);
  final last = CalendarDate(2027, 1, 6);

  RangeSummary summaryWith(List<CalendarDate> blocked) => summarizeRange(
    first,
    last,
    AvailabilitySnapshot(
      rules: weekdayRules(),
      blocked: {for (final d in blocked) d: BlockedDay(id: 'b-$d', date: d)},
    ),
  );

  final holidays = [
    CalendarDate(2026, 12, 25),
    CalendarDate(2027, 1, 1),
    CalendarDate(2027, 1, 6),
  ];

  /// Abre el diálogo desde un botón y guarda lo que devuelve en [result].
  Future<void> open(
    WidgetTester tester,
    RangeSummary summary,
    void Function(BlockRangeChoice?) result, {
    Locale locale = const Locale('it'),
  }) async {
    await pumpLocalized(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result(
              await showBlockRangeDialog(
                context,
                first: first,
                last: last,
                summary: summary,
              ),
            ),
            child: const Text('apri'),
          ),
        ),
      ),
      locale: locale,
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
  }

  testWidgets('del 21/12 al 6/1: resumen, «Sblocca 3 giorni» y «Blocca 14 giorni»', (
    tester,
  ) async {
    await open(tester, summaryWith(holidays), (_) {});

    expect(find.byType(BlockRangeDialog), findsOneWidget);
    expect(find.text('Dal 21 dic 2026 al 6 gen 2027'), findsOneWidget);
    expect(find.text('17 giorni · 13 in cui lavori · 3 già bloccati'), findsOneWidget);
    expect(find.text('Sblocca 3 giorni'), findsOneWidget);
    expect(find.text('Blocca 14 giorni'), findsOneWidget);
    expect(find.text('Annulla'), findsOneWidget);
    // La nota: letra de 16 px o más (si no, iOS hace zoom).
    expect(find.byKey(const ValueKey('block-range-note')), findsOneWidget);
    expectReadableInputs(tester);
  });

  testWidgets('«Blocca» devuelve la nota escrita', (tester) async {
    BlockRangeChoice? choice;
    await open(tester, summaryWith(holidays), (c) => choice = c);

    await tester.enterText(find.byKey(const ValueKey('block-range-note')), 'Ferie di Natale');
    await tester.tap(find.byKey(const ValueKey('block-range-confirm')));
    await tester.pumpAndSettle();

    expect(choice, isA<BlockRangeBlock>());
    expect((choice! as BlockRangeBlock).note, 'Ferie di Natale');
    expect(find.byType(BlockRangeDialog), findsNothing);
  });

  testWidgets('«Sblocca» y «Annulla»', (tester) async {
    BlockRangeChoice? choice;
    await open(tester, summaryWith(holidays), (c) => choice = c);
    await tester.tap(find.byKey(const ValueKey('block-range-unblock')));
    await tester.pumpAndSettle();
    expect(choice, isA<BlockRangeUnblock>());

    choice = const BlockRangeUnblock();
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('block-range-cancel')));
    await tester.pumpAndSettle();
    expect(choice, isNull);
  });

  testWidgets('sin días bloqueados no ofrece «Sblocca»; con todos bloqueados, ni «Blocca» ni la nota', (
    tester,
  ) async {
    await open(tester, summaryWith(const []), (_) {});
    expect(find.text('17 giorni · 13 in cui lavori'), findsOneWidget);
    expect(find.byKey(const ValueKey('block-range-unblock')), findsNothing);
    expect(find.text('Blocca 17 giorni'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('block-range-cancel')));
    await tester.pumpAndSettle();

    final everyDay = datesInRange(first, last);
    await open(tester, summaryWith(everyDay), (_) {});
    expect(find.text('Sblocca 17 giorni'), findsOneWidget);
    expect(find.byKey(const ValueKey('block-range-confirm')), findsNothing);
    expect(find.byKey(const ValueKey('block-range-note')), findsNothing);
  });

  testWidgets('un fin de semana solo: «nessuno in cui lavori»', (tester) async {
    final saturday = CalendarDate(2026, 12, 26);
    await pumpLocalized(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBlockRangeDialog(
              context,
              first: saturday,
              last: saturday.addDays(1),
              summary: summarizeRange(
                saturday,
                saturday.addDays(1),
                AvailabilitySnapshot(rules: weekdayRules()),
              ),
            ),
            child: const Text('apri'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
    expect(find.text('2 giorni · nessuno in cui lavori'), findsOneWidget);
    expect(find.text('Blocca 2 giorni'), findsOneWidget);
  });

  for (final (locale, title, line) in [
    (
      const Locale('es'),
      'Del 21 dic 2026 al 6 ene 2027',
      '17 días · 13 que trabajas · 3 ya bloqueados',
    ),
    (
      const Locale('en'),
      'From Dec 21, 2026 to Jan 6, 2027',
      '17 days · 13 you work · 3 already blocked',
    ),
  ]) {
    testWidgets('en ${locale.languageCode}', (tester) async {
      await open(tester, summaryWith(holidays), (_) {}, locale: locale);
      expect(find.text(title), findsOneWidget);
      expect(find.text(line), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

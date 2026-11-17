// Diálogo de un rango de días: título, resumen ("17 giorni · 13 in cui lavori
// · 3 già bloccati"), nota con letra de 16 px o más (que se sigue viendo con
// el teclado abierto a 375×667) y las tres salidas.
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
    int sessionDays = 0,
    bool sessionsKnown = true,
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
                sessionDays: sessionDays,
                sessionsKnown: sessionsKnown,
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

  final note = find.byKey(const ValueKey('block-range-note'));

  testWidgets('si algunos días del rango tienen sesiones, avisa que bloquearlos no las cancela', (
    tester,
  ) async {
    await open(tester, summaryWith(const []), (_) {}, sessionDays: 2);
    expect(
      find.text('2 di questi giorni hanno sessioni: bloccarli non le annulla.'),
      findsOneWidget,
    );
  });

  testWidgets('sin sesiones en el rango, no dice nada de sesiones', (tester) async {
    await open(tester, summaryWith(const []), (_) {});
    expect(find.byKey(const ValueKey('block-range-sessions')), findsNothing);
    expect(find.byKey(const ValueKey('block-range-sessions-unknown')), findsNothing);
  });

  testWidgets('si las sesiones no se pudieron leer, dice que no se sabe (no «0»)', (tester) async {
    await open(tester, summaryWith(const []), (_) {}, sessionsKnown: false);
    expect(
      find.text('Non è stato possibile verificare se questi giorni hanno sessioni.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('block-range-sessions')), findsNothing);
  });

  testWidgets('del 21/12 al 6/1: resumen, «Sblocca 3 giorni» y «Blocca 14 giorni»', (
    tester,
  ) async {
    await open(tester, summaryWith(holidays), (_) {});

    expect(find.byType(BlockRangeDialog), findsOneWidget);
    // Cada fecha con espacios que no cortan: el renglón se parte entre las
    // fechas, no en medio de una.
    expect(find.text('Dal 21\u00a0dic\u00a02026 al 6\u00a0gen\u00a02027'), findsOneWidget);
    expect(find.text('17 giorni · 13 in cui lavori · 3 già bloccati'), findsOneWidget);
    expect(find.text('Sblocca 3 giorni'), findsOneWidget);
    expect(find.text('Blocca 14 giorni'), findsOneWidget);
    expect(find.text('Annulla'), findsOneWidget);
    // La nota: letra de 16 px o más (si no, iOS hace zoom), el ejemplo como
    // pista y, siempre a la vista (también sin foco), que no lleve datos de
    // salud.
    expect(note, findsOneWidget);
    expectReadableInputs(tester);
    final decoration = tester.widget<TextField>(note).decoration!;
    expect(decoration.hintText, 'Es.: ferie');
    expect(find.text('Non scrivere dati sulla salute.'), findsOneWidget);
    expect(decoration.helperMaxLines, 2);
  });

  testWidgets('arriba, desplazable, nota de hasta 200 letras con mayúscula al empezar', (
    tester,
  ) async {
    await open(tester, summaryWith(holidays), (_) {});
    final dialog = tester.widget<AlertDialog>(
      find.byKey(const ValueKey('block-range-dialog')),
    );
    expect(dialog.alignment, Alignment.topCenter);
    expect(dialog.scrollable, isTrue);
    expect(
      tester.widget<TextField>(note).textCapitalization,
      TextCapitalization.sentences,
    );

    await tester.enterText(note, 'x' * 250);
    final editable = find.descendant(of: note, matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(editable).controller.text, hasLength(maxNoteLength));
  });

  // El teclado de un iPhone SE con predicciones y la barra de formulario
  // ocupa unos 300 pt; Flutter web lo informa como viewInsets.
  for (final locale in const [Locale('es'), Locale('it')]) {
    testWidgets('a 375×667 con el teclado abierto, la nota se ve y «Blocca» queda a mano (${locale.languageCode})', (
      tester,
    ) async {
      setSurfaceSize(tester, const Size(375, 667));
      await open(tester, summaryWith(holidays), (_) {}, locale: locale);
      await tester.tap(note);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();

      final scroll = find.descendant(
        of: find.byKey(const ValueKey('block-range-dialog')),
        matching: find.byType(SingleChildScrollView),
      );
      final visible = tester.getRect(note).intersect(tester.getRect(scroll));
      expect(visible.height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(of: note, matching: find.byType(EditableText)).hitTestable(),
        findsOneWidget,
      );
      final confirm = find.byKey(const ValueKey('block-range-confirm'));
      expect(confirm.hitTestable(), findsOneWidget);
      expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(667 - 300));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('un solo día: el título es la fecha, sin «Dal … al …»', (tester) async {
    final day = CalendarDate(2026, 11, 18);
    await pumpLocalized(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBlockRangeDialog(
              context,
              first: day,
              last: day,
              summary: summarizeRange(day, day, AvailabilitySnapshot(rules: weekdayRules())),
            ),
            child: const Text('apri'),
          ),
        ),
      ),
      locale: const Locale('es'),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
    expect(find.text('18\u00a0nov\u00a02026'), findsOneWidget);
    expect(find.text('1 día · 1 en el que trabajas'), findsOneWidget);
    expect(find.text('Bloquear 1 día'), findsOneWidget);
  });

  testWidgets('«Blocca» devuelve la nota escrita', (tester) async {
    BlockRangeChoice? choice;
    await open(tester, summaryWith(holidays), (c) => choice = c);

    await tester.enterText(note, 'Ferie di Natale');
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
    expect(note, findsNothing);
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
      'Del 21\u00a0dic\u00a02026 al 6\u00a0ene\u00a02027',
      '17 días · 13 en los que trabajas · 3 ya bloqueados',
    ),
    (
      const Locale('en'),
      'From Dec\u00a021,\u00a02026 to Jan\u00a06,\u00a02027',
      '17 days · 13 working days · 3 already blocked',
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

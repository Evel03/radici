// Las horas de una sesión («Llega 10:00 · hasta 13:00», sin compra)
// en un teléfono, medidas con la letra de verdad (la Roboto empaquetada, la
// que dibuja /gestione/ también en el iPhone): el renglón se parte solo
// después de un «·», nunca entre «hasta» (o «fino alle», «until») y la hora.
// En la ficha (16 px) y en el bloque de la semana de la agenda (14 px).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/pump_app.dart';
import '../../../support/session_fixtures.dart';

/// Los renglones de [paragraph], como los dibuja.
List<String> _linesOf(RenderParagraph paragraph) {
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  )..layout(maxWidth: paragraph.constraints.maxWidth);
  final text = paragraph.text.toPlainText();
  final ranges = <int, TextRange>{};
  for (var offset = 0; offset < text.length; offset++) {
    final range = painter.getLineBoundary(TextPosition(offset: offset));
    ranges.putIfAbsent(range.start, () => range);
  }
  painter.dispose();
  return [
    for (final range in ranges.values) text.substring(range.start, range.end),
  ];
}

/// Cada renglón, salvo el último, termina en «·» (trimRight también quita
/// los espacios que no cortan), y ninguno empieza con «·».
void _expectBreaksOnlyAfterDots(List<String> lines, String where) {
  final shown = plainSpaces(lines.join(' / '));
  for (final (index, line) in lines.indexed) {
    if (index < lines.length - 1) {
      expect(line.trimRight(), endsWith('·'), reason: '$where: $shown');
    }
    expect(line.trimLeft(), isNot(startsWith('·')), reason: '$where: $shown');
  }
}

void main() {
  setUpAll(() async {
    // En los tests las fuentes del pubspec no se cargan solas.
    final roboto = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Medium.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await roboto.load();
  });

  RenderParagraph paragraphOf(WidgetTester tester, String key) =>
      tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(RichText),
        ),
      );

  const widths = [320.0, 360.0, 375.0, 390.0, 414.0, 430.0];
  const locales = [Locale('es'), Locale('it'), Locale('en')];

  for (final locale in locales) {
    testWidgets(
      'en la ficha, a cualquier ancho de teléfono (${locale.languageCode})',
      (tester) async {
        await pumpChefApp(
          tester,
          requests: FakeChefRequestsRepository(const []),
          sessions: FakeSessionsRepository(buildBooking()),
          location: '/sessioni/${sessionId(2)}',
          size: Size(widths.first, 800),
          deviceLocales: [locale],
        );
        for (final width in widths) {
          setSurfaceSize(tester, Size(width, 800));
          await tester.pumpAndSettle();
          final lines = _linesOf(paragraphOf(tester, 'session-times'));
          _expectBreaksOnlyAfterDots(lines, 'ficha a $width');
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      'en el bloque de la semana de la agenda, a cualquier ancho de teléfono (${locale.languageCode})',
      (tester) async {
        await pumpChefApp(
          tester,
          requests: FakeChefRequestsRepository(const []),
          sessions: FakeSessionsRepository(
            buildBooking(first: CalendarDate(2026, 10, 21)),
          ),
          location: '/agenda',
          size: Size(widths.first, 1200),
          deviceLocales: [locale],
        );
        await tester.tap(find.byKey(const ValueKey('agenda-view-week')));
        await tester.pumpAndSettle();
        for (final width in widths) {
          setSurfaceSize(tester, Size(width, 1200));
          await tester.pumpAndSettle();
          final lines = _linesOf(
            paragraphOf(tester, 'session-${sessionId(1)}-times'),
          );
          _expectBreaksOnlyAfterDots(lines, 'semana a $width');
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}

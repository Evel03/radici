// La fila de un pedido de varias semanas en un teléfono de 375 px, medida con
// la letra de verdad (Roboto empaquetada, la de /gestione/): el resumen
// («… · 4 settimane · 4 persone · 5 giorni · Cena») se corta en dos líneas y
// la fecha preferida sigue a la vista en la tercera. En un solo texto de tres
// líneas, el resumen la tapaba.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';

void main() {
  setUpAll(() async {
    // En los tests las fuentes del pubspec no se cargan solas.
    final roboto = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Medium.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await roboto.load();
  });

  for (final (locale, dateLine) in const [
    (Locale('es', 'ES'), 'lun, 23 nov · Mañana'),
    (Locale('it', 'IT'), 'lun 23 nov · Mattina'),
  ]) {
    testWidgets(
      'a 375 px se ve la fecha de una reserva de 4 semanas (${locale.languageCode})',
      (tester) async {
        await pumpChefApp(
          tester,
          requests: FakeChefRequestsRepository([
            buildRequest(
              id: 'booked-1',
              status: RequestStatus.accepted,
              weeks: 4,
              preferredDate: CalendarDate(2026, 11, 23),
              seenAt: testNow,
            ),
          ]),
          size: const Size(375, 667),
          deviceLocales: [locale],
          location: '/richieste',
        );
        final tab = find.byKey(const ValueKey('inbox-tab-bookings'));
        await tester.ensureVisible(tab);
        await tester.pumpAndSettle();
        await tester.tap(tab);
        await tester.pumpAndSettle();

        final date = find.byKey(const ValueKey('request-booked-1-when'));
        expect(tester.widget<Text>(date).data, dateLine);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: date, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: 'entra entera');
        final row = tester.getRect(find.byKey(const ValueKey('request-booked-1')));
        final line = tester.getRect(date);
        expect(line.height, greaterThan(0));
        expect(line.top, greaterThanOrEqualTo(row.top));
        expect(line.bottom, lessThanOrEqualTo(row.bottom));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

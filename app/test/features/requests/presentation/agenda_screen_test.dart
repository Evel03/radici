// Agenda: vista mensual y semanal con franjas, y lista "senza data".
// "Hoy" en los tests: lunes 19/10/2026 (testNow).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/core/rome_time.dart';
import 'package:mestolo/features/requests/domain/chef_request.dart';
import 'package:mestolo/features/requests/presentation/agenda_screen.dart';
import 'package:mestolo/features/requests/presentation/request_detail_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';

void main() {
  final wednesday = CalendarDate(2026, 10, 21);

  FakeChefRequestsRepository sample() => FakeChefRequestsRepository([
    buildRequest(
      id: 'morning',
      name: 'Giulia Rossi',
      preferredDate: wednesday,
      preferredSlot: PreferredSlot.morning,
    ),
    buildRequest(
      id: 'afternoon',
      name: 'Marco Bianchi',
      preferredDate: wednesday,
      preferredSlot: PreferredSlot.afternoon,
    ),
    buildRequest(
      id: 'rejected',
      name: 'Luca Neri',
      preferredDate: wednesday,
      status: RequestStatus.rejected,
    ),
    buildRequest(
      id: 'november',
      name: 'Anna Verdi',
      preferredDate: CalendarDate(2026, 11, 2),
    ),
    buildRequest(id: 'no-date', name: 'Sara Gialli', noDate: true),
  ]);

  Future<ChefApp> openAgenda(WidgetTester tester) async {
    final app = await pumpChefApp(
      tester,
      requests: sample(),
      location: '/agenda',
      size: const Size(400, 2000),
    );
    expect(find.byType(AgendaScreen), findsOneWidget);
    return app;
  }

  Finder day(String iso) => find.byKey(ValueKey('agenda-day-$iso'));
  Finder tile(String id) => find.byKey(ValueKey('request-$id'));

  testWidgets('vista mensual: octubre 2026 con la cantidad de pedidos por día', (
    tester,
  ) async {
    await openAgenda(tester);

    expect(find.text('ottobre 2026'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('agenda-day-count-2026-10-21'))).data,
      '2',
      reason: 'el rechazado no cuenta',
    );
    expect(find.byKey(const ValueKey('agenda-day-count-2026-10-20')), findsNothing);
    // Hoy (19/10) está elegido y no tiene pedidos.
    expect(find.text('Nessuna richiesta per questo giorno.'), findsOneWidget);
  });

  testWidgets('elegir un día muestra sus pedidos con la franja', (tester) async {
    await openAgenda(tester);

    await tester.tap(day('2026-10-21'));
    await tester.pumpAndSettle();

    expect(find.text('mercoledì 21 ottobre 2026'), findsOneWidget);
    expect(tile('morning'), findsOneWidget);
    expect(tile('afternoon'), findsOneWidget);
    expect(tile('rejected'), findsNothing);
    expect(find.descendant(of: tile('morning'), matching: find.textContaining('Mattina')), findsOneWidget);
    expect(
      find.descendant(of: tile('afternoon'), matching: find.textContaining('Pomeriggio')),
      findsOneWidget,
    );
    // Mañana antes que tarde.
    expect(
      tester.getTopLeft(tile('morning')).dy,
      lessThan(tester.getTopLeft(tile('afternoon')).dy),
    );
  });

  testWidgets('mes siguiente y volver a hoy', (tester) async {
    await openAgenda(tester);
    await tester.tap(find.byKey(const ValueKey('agenda-next')));
    await tester.pumpAndSettle();
    expect(find.text('novembre 2026'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('agenda-day-count-2026-11-02'))).data,
      '1',
    );

    await tester.tap(find.byKey(const ValueKey('agenda-today')));
    await tester.pumpAndSettle();
    expect(find.text('ottobre 2026'), findsOneWidget);
  });

  testWidgets('vista semanal: días de lunes a domingo con pedidos y franjas', (
    tester,
  ) async {
    await openAgenda(tester);
    await tester.tap(find.byKey(const ValueKey('agenda-view-week')));
    await tester.pumpAndSettle();

    expect(find.text('19 ott – 25 ott 2026'), findsOneWidget);
    for (var d = 19; d <= 25; d++) {
      expect(find.byKey(ValueKey('agenda-week-day-2026-10-$d')), findsOneWidget);
    }
    final wednesdayCard = find.byKey(const ValueKey('agenda-week-day-2026-10-21'));
    expect(find.descendant(of: wednesdayCard, matching: tile('morning')), findsOneWidget);
    expect(find.descendant(of: wednesdayCard, matching: find.textContaining('Pomeriggio')), findsOneWidget);

    // La semana cruza el mes; el 2/11 (lunes) ya es de la semana siguiente.
    await tester.tap(find.byKey(const ValueKey('agenda-next')));
    await tester.pumpAndSettle();
    expect(find.text('26 ott – 1 nov 2026'), findsOneWidget);
    expect(tile('november'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('agenda-next')));
    await tester.pumpAndSettle();
    expect(find.text('2 nov – 8 nov 2026'), findsOneWidget);
    expect(tile('november'), findsOneWidget);
  });

  testWidgets('"senza data" lista los pedidos sin fecha', (tester) async {
    await openAgenda(tester);
    final list = find.byKey(const ValueKey('agenda-without-date'));
    expect(find.descendant(of: list, matching: tile('no-date')), findsOneWidget);
    expect(find.descendant(of: list, matching: tile('morning')), findsNothing);
  });

  testWidgets('tocar un pedido abre el detalle y volver regresa a la agenda', (
    tester,
  ) async {
    await openAgenda(tester);
    await tester.tap(tile('no-date'));
    await tester.pumpAndSettle();
    expect(find.byType(RequestDetailScreen), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(AgendaScreen), findsOneWidget);
  });

  for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
    testWidgets('teléfono angosto sin desbordes (${locale.languageCode})', (
      tester,
    ) async {
      await pumpChefApp(
        tester,
        requests: sample(),
        location: '/agenda',
        size: const Size(320, 640),
        deviceLocales: [locale],
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('agenda-view-week')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

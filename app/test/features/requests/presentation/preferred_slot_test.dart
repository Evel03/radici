// Franja preferida: la web ya no la pregunta y manda "any" (contrato §3), así
// que un pedido nuevo no muestra «Indifferente» en la bandeja, el detalle ni la
// agenda. Un pedido de antes, con mañana o tarde, la sigue mostrando.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';

void main() {
  // Como llegan de la base, los dos para el miércoles 21/10: uno nuevo de la
  // web (franja "any") y uno de antes, con la mañana.
  FakeChefRequestsRepository sample() => FakeChefRequestsRepository([
    ChefRequest.fromJson(
      requestRow(
        id: 'nuovo',
        name: 'Giulia Rossi',
        preferredSlot: 'any',
        createdAt: '2026-10-19T09:15:00Z',
      ),
    ),
    ChefRequest.fromJson(
      requestRow(
        id: 'vecchio',
        name: 'Marco Bianchi',
        preferredSlot: 'morning',
        createdAt: '2026-10-18T09:15:00Z',
      ),
    ),
  ]);

  Finder tile(String id) => find.byKey(ValueKey('request-$id'));
  Finder inTile(String id, String text) =>
      find.descendant(of: tile(id), matching: find.textContaining(text));

  test('"any" se lee como sin franja; mañana y tarde, como siempre', () {
    expect(
      ChefRequest.fromJson(requestRow(preferredSlot: 'any')).preferredSlot,
      isNull,
    );
    expect(
      ChefRequest.fromJson(requestRow(preferredSlot: 'morning')).preferredSlot,
      PreferredSlot.morning,
    );
    expect(
      ChefRequest.fromJson(
        requestRow(preferredSlot: 'afternoon'),
      ).preferredSlot,
      PreferredSlot.afternoon,
    );
  });

  testWidgets('bandeja: el nuevo sin «Indifferente»; el de antes, con «Mattina»', (
    tester,
  ) async {
    await pumpChefApp(tester, requests: sample(), location: '/richieste');

    expect(tile('nuovo'), findsOneWidget);
    expect(inTile('nuovo', 'mer 21 ott'), findsOneWidget);
    expect(inTile('vecchio', 'mer 21 ott · Mattina'), findsOneWidget);
    expect(find.textContaining('Indifferente'), findsNothing);
  });

  testWidgets('detalle: el nuevo sin la fila de la franja; el de antes, con ella', (
    tester,
  ) async {
    final app = await pumpChefApp(tester, requests: sample());

    app.go('/richieste/nuovo');
    await tester.pumpAndSettle();
    expect(find.byType(RequestDetailScreen), findsOneWidget);
    expect(find.text('Data preferita'), findsOneWidget);
    expect(find.text('Fascia oraria'), findsNothing);
    expect(find.text('Indifferente'), findsNothing);

    app.go('/richieste/vecchio');
    await tester.pumpAndSettle();
    expect(find.text('Fascia oraria'), findsOneWidget);
    expect(find.text('Mattina'), findsOneWidget);
  });

  testWidgets('agenda (día y semana): el nuevo sin franja; el de antes, con «Mattina»', (
    tester,
  ) async {
    await pumpChefApp(
      tester,
      requests: sample(),
      location: '/agenda',
      size: const Size(400, 2000),
    );
    expect(find.byType(AgendaScreen), findsOneWidget);
    final wednesday = CalendarDate(2026, 10, 21).toIso();

    await tester.tap(find.byKey(ValueKey('agenda-day-$wednesday')));
    await tester.pumpAndSettle();
    expect(tile('nuovo'), findsOneWidget);
    expect(inTile('vecchio', 'Mattina'), findsOneWidget);
    expect(find.textContaining('Indifferente'), findsNothing);
    // El de antes va primero: la mañana antes que sin franja.
    expect(
      tester.getTopLeft(tile('vecchio')).dy,
      lessThan(tester.getTopLeft(tile('nuovo')).dy),
    );

    await tester.tap(find.byKey(const ValueKey('agenda-view-week')));
    await tester.pumpAndSettle();
    final wednesdayCard = find.byKey(ValueKey('agenda-week-day-$wednesday'));
    expect(
      find.descendant(of: wednesdayCard, matching: tile('nuovo')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: wednesdayCard, matching: find.textContaining('Mattina')),
      findsOneWidget,
    );
    expect(find.textContaining('Indifferente'), findsNothing);
  });
}

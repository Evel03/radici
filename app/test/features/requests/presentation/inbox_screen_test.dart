// Bandeja: pestañas, contador, lista y navegación al detalle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';

void main() {
  FakeChefRequestsRepository sample() => FakeChefRequestsRepository([
    buildRequest(id: 'new-1', name: 'Giulia Rossi', createdAt: DateTime.utc(2026, 10, 19, 9)),
    buildRequest(
      id: 'new-2',
      name: 'Marco Bianchi',
      noDate: true,
      weeks: 4,
      createdAt: DateTime.utc(2026, 10, 19, 8),
    ),
    buildRequest(
      id: 'seen-1',
      name: 'Anna Verdi',
      seenAt: DateTime.utc(2026, 10, 18, 10),
      createdAt: DateTime.utc(2026, 10, 18, 9),
    ),
    buildRequest(
      id: 'rejected-1',
      name: 'Luca Neri',
      status: RequestStatus.rejected,
      seenAt: DateTime.utc(2026, 10, 17, 10),
      createdAt: DateTime.utc(2026, 10, 17, 9),
    ),
    // Una reserva confirmada (pedido aceptado) de 4 semanas.
    buildRequest(
      id: 'booked-1',
      name: 'Sara Gialli',
      status: RequestStatus.accepted,
      weeks: 4,
      seenAt: DateTime.utc(2026, 10, 16, 10),
      createdAt: DateTime.utc(2026, 10, 16, 9),
    ),
  ]);

  Finder tile(String id) => find.byKey(ValueKey('request-$id'));

  /// Toca una pestaña; la barra se desliza si no entra entera.
  Future<void> openTab(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('nuevas primero, con contador en la pestaña y en la navegación', (
    tester,
  ) async {
    await pumpChefApp(tester, requests: sample());

    expect(find.byType(InboxScreen), findsOneWidget);
    expect(tile('new-1'), findsOneWidget);
    expect(tile('new-2'), findsOneWidget);
    expect(tile('seen-1'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('inbox-new-count')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    final badge = tester.widget<Badge>(
      find.byKey(const ValueKey('new-requests-badge')).first,
    );
    expect(badge.isLabelVisible, isTrue);

    // Resumen y fecha preferida.
    expect(
      find.descendant(
        of: tile('new-1'),
        matching: find.textContaining('Settimana di pasti · 4 persone · 5 giorni · Cena'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile('new-2'), matching: find.textContaining('Senza data')),
      findsOneWidget,
    );
    // Un pedido de varias semanas lo dice; uno de una semana, no.
    expect(
      find.descendant(
        of: tile('new-2'),
        matching: find.textContaining('Settimana di pasti · 4 settimane · 4 persone'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile('new-1'), matching: find.textContaining('settimane')),
      findsNothing,
    );
  });

  testWidgets('pestañas Viste, Prenotazioni y Rifiutate', (tester) async {
    await pumpChefApp(tester, requests: sample());

    await openTab(tester, 'inbox-tab-seen');
    expect(tile('seen-1'), findsOneWidget);
    expect(tile('new-1'), findsNothing);
    // Una reserva ya no está en Viste.
    expect(tile('booked-1'), findsNothing);

    await openTab(tester, 'inbox-tab-bookings');
    expect(find.text('Prenotazioni'), findsOneWidget);
    expect(tile('booked-1'), findsOneWidget);
    expect(tile('seen-1'), findsNothing);
    expect(
      find.descendant(
        of: tile('booked-1'),
        matching: find.textContaining('Settimana di pasti · 4 settimane'),
      ),
      findsOneWidget,
    );

    await openTab(tester, 'inbox-tab-rejected');
    expect(tile('rejected-1'), findsOneWidget);
    expect(tile('booked-1'), findsNothing);
  });

  testWidgets('cuatro pestañas, cada una con el ancho de su texto', (tester) async {
    await pumpChefApp(tester, requests: sample());
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.tabs, hasLength(4));
    expect(tabBar.isScrollable, isTrue);
    expect(tabBar.tabAlignment, TabAlignment.start);
  });

  testWidgets('pestañas vacías', (tester) async {
    await pumpChefApp(tester, requests: FakeChefRequestsRepository(const []));
    expect(find.text('Nessuna richiesta nuova.'), findsOneWidget);
    final badge = tester.widget<Badge>(
      find.byKey(const ValueKey('new-requests-badge')).first,
    );
    expect(badge.isLabelVisible, isFalse);

    // La de reservas dice dónde se confirman.
    await openTab(tester, 'inbox-tab-bookings');
    expect(
      find.text('Nessuna prenotazione. Le confermi dal dettaglio di una richiesta nuova.'),
      findsOneWidget,
    );
  });

  testWidgets('confirmar una reserva la pasa de Viste a Prenotazioni', (tester) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([
        buildRequest(
          id: 'req-1',
          weeks: 4,
          preferredDate: CalendarDate(2026, 11, 23),
          estimate: fourWeeksEstimate,
          seenAt: testNow,
        ),
      ]),
    );
    await openTab(tester, 'inbox-tab-seen');
    await tester.tap(tile('req-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-confirm-booking')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('booking-confirm')));
    await tester.pumpAndSettle();
    expect(app.bookings.confirmations, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('booking-done-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(tile('req-1'), findsNothing, reason: 'ya no está en Viste');
    await openTab(tester, 'inbox-tab-bookings');
    expect(tile('req-1'), findsOneWidget);
    expect(
      find.descendant(of: tile('req-1'), matching: find.textContaining('4 settimane')),
      findsOneWidget,
    );
  });

  testWidgets('abrir un pedido lo marca visto y baja el contador', (tester) async {
    final app = await pumpChefApp(tester, requests: sample());

    await tester.tap(tile('new-1'));
    await tester.pumpAndSettle();
    expect(find.byType(RequestDetailScreen), findsOneWidget);
    expect(app.requests.markedSeen, ['new-1']);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(tile('new-1'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('inbox-new-count')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('error al cargar: mensaje y reintentar', (tester) async {
    final requests = sample()..failFetch = true;
    await pumpChefApp(tester, requests: requests);
    expect(
      find.text(
        'Impossibile caricare le richieste. Controlla la connessione e riprova.',
      ),
      findsOneWidget,
    );

    requests.failFetch = false;
    await tester.tap(find.byKey(const ValueKey('load-error-retry')));
    await tester.pumpAndSettle();
    expect(tile('new-1'), findsOneWidget);
  });

  testWidgets('deslizar para actualizar trae pedidos nuevos', (tester) async {
    final app = await pumpChefApp(tester, requests: sample());
    app.requests.insertSilently(
      buildRequest(id: 'late', name: 'Sara Gialli', createdAt: DateTime.utc(2026, 10, 19, 11)),
    );

    await tester.fling(find.byKey(const ValueKey('inbox-list-fresh')), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(tile('late'), findsOneWidget);
  });

  testWidgets('pantalla ancha (web en computadora): riel lateral', (tester) async {
    await pumpChefApp(tester, requests: sample(), size: const Size(1200, 800));
    expect(find.byKey(const ValueKey('chef-nav-rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('chef-nav-bar')), findsNothing);
  });

  for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
    testWidgets('teléfono angosto sin desbordes (${locale.languageCode})', (
      tester,
    ) async {
      await pumpChefApp(
        tester,
        requests: sample(),
        size: const Size(320, 640),
        deviceLocales: [locale],
      );
      expect(tester.takeException(), isNull);
      expect(tile('new-1'), findsOneWidget);
    });
  }
}

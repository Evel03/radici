// Bandeja: pestañas, contador, lista y navegación al detalle. Ya no es el
// inicio de la cocinera (es Hoy): los tests la abren en /richieste.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/presentation/new_booking_client_screen.dart';
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
    await pumpChefApp(tester, requests: sample(), location: '/richieste');

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
    await pumpChefApp(tester, requests: sample(), location: '/richieste');

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
    await pumpChefApp(tester, requests: sample(), location: '/richieste');
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.tabs, hasLength(4));
    expect(tabBar.isScrollable, isTrue);
    expect(tabBar.tabAlignment, TabAlignment.start);
  });

  testWidgets('pestañas vacías', (tester) async {
    await pumpChefApp(tester, requests: FakeChefRequestsRepository(const []), location: '/richieste');
    expect(find.text('Nessuna richiesta nuova.'), findsOneWidget);
    final badge = tester.widget<Badge>(
      find.byKey(const ValueKey('new-requests-badge')).first,
    );
    expect(badge.isLabelVisible, isFalse);

    // La de reservas dice dónde se confirman y propone la de abajo.
    await openTab(tester, 'inbox-tab-bookings');
    expect(
      find.text(
        'Nessuna prenotazione. Confermane una da una richiesta nuova o creala '
        'qui sotto con «Nuova prenotazione».',
      ),
      findsOneWidget,
    );
  });

  group('«Nuova prenotazione» en Prenotazioni', () {
    final newBooking = find.byKey(const ValueKey('inbox-new-booking'));

    testWidgets('solo la pestaña Prenotazioni tiene la barra, y abre el elegir', (tester) async {
      await pumpChefApp(tester, requests: sample(), location: '/richieste');
      expect(newBooking, findsNothing, reason: 'en «Nuove» no');
      await openTab(tester, 'inbox-tab-seen');
      expect(newBooking, findsNothing);
      await openTab(tester, 'inbox-tab-rejected');
      expect(newBooking, findsNothing);
      await openTab(tester, 'inbox-tab-bookings');
      expect(newBooking.hitTestable(), findsOneWidget);
      expect(find.text('Nuova prenotazione'), findsOneWidget);

      await tester.tap(newBooking);
      await tester.pumpAndSettle();
      expect(find.byType(NewBookingClientScreen), findsOneWidget);
    });

    testWidgets('con la bandeja cargando o con error, la barra está igual', (tester) async {
      final requests = sample()..pendingFetch = Completer<void>();
      await pumpChefApp(
        tester,
        requests: requests,
        location: '/richieste',
        settle: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('inbox-tab-bookings')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(newBooking.hitTestable(), findsOneWidget);
      await tester.tap(newBooking);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(NewBookingClientScreen), findsOneWidget);
      requests.pendingFetch!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('con la bandeja en error, la barra está debajo del error y abre el elegir', (tester) async {
      final requests = sample()..failFetch = true;
      await pumpChefApp(tester, requests: requests, location: '/richieste');
      await openTab(tester, 'inbox-tab-bookings');
      expect(find.byKey(const ValueKey('load-error')), findsOneWidget);
      expect(newBooking.hitTestable(), findsOneWidget);
      await tester.tap(newBooking);
      await tester.pumpAndSettle();
      expect(find.byType(NewBookingClientScreen), findsOneWidget);
    });

    testWidgets('una reserva a mano en la lista no dice «Senza data»; una de la web sí dice su fecha', (tester) async {
      await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([
          buildRequest(
            id: 'manual-1',
            name: 'Chiara Rossi',
            source: RequestSource.app,
            status: RequestStatus.accepted,
            noDate: true,
            preferredSlot: null,
            estimate: null,
            seenAt: testNow,
          ),
          buildRequest(
            id: 'web-1',
            status: RequestStatus.accepted,
            preferredDate: CalendarDate(2026, 11, 23),
            seenAt: testNow,
            createdAt: DateTime.utc(2026, 10, 18, 9),
          ),
        ]),
        location: '/richieste',
      );
      await openTab(tester, 'inbox-tab-bookings');
      expect(tile('manual-1'), findsOneWidget);
      expect(
        find.descendant(of: tile('manual-1'), matching: find.textContaining('Senza data')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('request-manual-1-when')), findsNothing);
      expect(tester.widget<ListTile>(tile('manual-1')).isThreeLine, isFalse);
      expect(find.byKey(const ValueKey('request-web-1-when')), findsOneWidget);
    });

    for (final empty in [true, false]) {
      testWidgets('a 375×667 el botón queda en el tercio inferior (${empty ? 'lista vacía' : 'con reservas'})', (tester) async {
        await pumpChefApp(
          tester,
          requests: empty ? FakeChefRequestsRepository(const []) : sample(),
          location: '/richieste',
          size: const Size(375, 667),
        );
        await openTab(tester, 'inbox-tab-bookings');
        expect(newBooking.hitTestable(), findsOneWidget);
        expect(tester.getCenter(newBooking).dy, greaterThan(667 * 2 / 3));
        expect(tester.getSize(newBooking).height, greaterThanOrEqualTo(48));
        expect(
          tester.getRect(newBooking).bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byKey(const ValueKey('chef-nav-bar'))).top,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('confirmar una reserva la pasa de Viste a Prenotazioni; la hoja y la pantalla final tapan la '
      'barra, y al volver está con sus 4 destinos y Richieste elegida', (tester) async {
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
      location: '/richieste',
    );
    final navBar = find.byKey(const ValueKey('chef-nav-bar'));
    expect(navBar, findsOneWidget);
    await openTab(tester, 'inbox-tab-seen');
    await tester.tap(tile('req-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-confirm-booking')));
    await tester.pumpAndSettle();
    expect(navBar, findsNothing, reason: 'la hoja tapa la barra');
    await tester.tap(find.byKey(const ValueKey('booking-confirm')));
    await tester.pumpAndSettle();
    expect(app.bookings.confirmations, hasLength(1));
    expect(find.byKey(const ValueKey('booking-done')), findsOneWidget);
    expect(navBar, findsNothing, reason: 'la pantalla final tapa la barra');

    await tester.tap(find.byKey(const ValueKey('booking-done-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(navBar.hitTestable(), findsOneWidget);
    expect(tester.widget<NavigationBar>(navBar).selectedIndex, 1);
    expect(
      find.descendant(of: navBar, matching: find.byType(NavigationDestination)),
      findsNWidgets(4),
    );
    expect(tile('req-1'), findsNothing, reason: 'ya no está en Viste');
    await openTab(tester, 'inbox-tab-bookings');
    expect(tile('req-1'), findsOneWidget);
    expect(
      find.descendant(of: tile('req-1'), matching: find.textContaining('4 settimane')),
      findsOneWidget,
    );
  });

  testWidgets('abrir un pedido lo marca visto y baja el contador', (tester) async {
    final app = await pumpChefApp(tester, requests: sample(), location: '/richieste');

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
    await pumpChefApp(tester, requests: requests, location: '/richieste');
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
    final app = await pumpChefApp(tester, requests: sample(), location: '/richieste');
    app.requests.insertSilently(
      buildRequest(id: 'late', name: 'Sara Gialli', createdAt: DateTime.utc(2026, 10, 19, 11)),
    );

    await tester.fling(find.byKey(const ValueKey('inbox-list-fresh')), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(tile('late'), findsOneWidget);
  });

  testWidgets('pantalla ancha (web en computadora): riel lateral', (tester) async {
    await pumpChefApp(tester, requests: sample(), size: const Size(1200, 800), location: '/richieste');
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
        location: '/richieste',
      );
      expect(tester.takeException(), isNull);
      expect(tile('new-1'), findsOneWidget);
    });
  }
}

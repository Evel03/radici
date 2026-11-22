// Aviso emergente en tiempo real: "Nuova richiesta da …" con botón para
// abrirla, en las pantallas de la cocinera salvo la ficha de una sesión y el
// formulario del editor de platos (tienen su propio ScaffoldMessenger y, en el
// navegador raíz, tapan el Scaffold de la barra): ahí aparece al volver.
// Con una hoja de reserva (también «Rinnova») o la ficha de una sesión (con
// su hoja «Sposta») abierta o tapada por otro pedido, «Apri» nunca la saca, y
// la hoja «Sposta» que termina de mover con un pedido encima no lo cierra.
// Con varios pedidos, «Apri» abre la bandeja en «Nuove» (también desde Hoy,
// con la bandeja dejada en otra pestaña).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/bookings/presentation/new_booking_client_screen.dart';
import 'package:radici/features/bookings/presentation/new_client_screen.dart';
import 'package:radici/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:radici/features/recipes/presentation/recipes_screen.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';
import 'package:radici/features/today/presentation/today_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/client_fixtures.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  final arrived = buildRequest(
    id: 'arrived',
    name: 'Marco Bianchi',
    createdAt: DateTime.utc(2026, 10, 19, 12),
  );
  const banner = ValueKey('new-request-banner');

  String bannerText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('new-request-banner-text')))
      .data!;

  testWidgets('llega un pedido: aviso con el nombre y "Apri" abre el detalle', (
    tester,
  ) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      location: '/richieste',
    );
    expect(find.byKey(banner), findsNothing);

    app.requests.insertFromRealtime(arrived);
    await tester.pumpAndSettle();

    expect(find.byKey(banner), findsOneWidget);
    expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi');
    // La lista y el contador ya se actualizaron.
    expect(find.byKey(const ValueKey('request-arrived')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-request-banner-open')));
    await tester.pumpAndSettle();

    expect(find.byType(RequestDetailScreen), findsOneWidget);
    expect(find.byKey(banner), findsNothing);
    expect(app.requests.markedSeen, ['arrived']);
  });

  testWidgets('el aviso aparece aunque esté en la agenda o en otro detalle', (
    tester,
  ) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      location: '/agenda',
    );
    expect(find.byType(AgendaScreen), findsOneWidget);

    app.requests.insertFromRealtime(arrived);
    await tester.pumpAndSettle();
    expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi');

    await tester.tap(find.byKey(const ValueKey('new-request-banner-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(banner), findsNothing);

    // Con el detalle de otro pedido abierto.
    app.go('/richieste/req-1');
    await tester.pumpAndSettle();
    app.requests.insertFromRealtime(
      buildRequest(id: 'third', name: 'Anna Verdi', createdAt: DateTime.utc(2026, 10, 19, 13)),
    );
    await tester.pumpAndSettle();
    expect(bannerText(tester), 'Nuova richiesta da Anna Verdi');
  });

  testWidgets('varios pedidos: un aviso con la cantidad que abre la bandeja', (
    tester,
  ) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      location: '/agenda',
    );
    app.requests
      ..insertFromRealtime(arrived)
      ..insertFromRealtime(
        buildRequest(id: 'second', name: 'Anna Verdi', createdAt: DateTime.utc(2026, 10, 19, 13)),
      );
    await tester.pumpAndSettle();
    expect(bannerText(tester), '2 nuove richieste');

    await tester.tap(find.byKey(const ValueKey('new-request-banner-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('request-second')), findsOneWidget);
    expect(find.byKey(const ValueKey('request-arrived')), findsOneWidget);
  });

  group('desde Hoy, con la bandeja dejada en «Viste»', () {
    Finder byKey(String key) => find.byKey(ValueKey(key));

    Future<ChefApp> openToday(WidgetTester tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([
          buildRequest(id: 'visto', seenAt: DateTime.utc(2026, 10, 18, 10)),
        ]),
      );
      Finder destination(String label) => find.descendant(
        of: byKey('chef-nav-bar'),
        matching: find.text(label),
      );
      expect(find.byType(TodayScreen), findsOneWidget);
      await tester.tap(destination('Richieste'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('inbox-tab-seen'));
      await tester.pumpAndSettle();
      expect(byKey('inbox-list-seen').hitTestable(), findsOneWidget);
      await tester.tap(destination('Oggi'));
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
      return app;
    }

    testWidgets('un pedido: el aviso sale sobre Hoy y «Apri» abre el detalle; al volver, Hoy', (
      tester,
    ) async {
      final app = await openToday(tester);
      app.requests.insertFromRealtime(arrived);
      await tester.pumpAndSettle();
      expect(find.byKey(banner).hitTestable(), findsOneWidget);

      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.byType(RequestDetailScreen), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
    });

    testWidgets('varios: «Apri» abre la bandeja en «Nuove», donde están, y no en «Viste»', (
      tester,
    ) async {
      final app = await openToday(tester);
      app.requests
        ..insertFromRealtime(arrived)
        ..insertFromRealtime(
          buildRequest(id: 'second', name: 'Anna Verdi', createdAt: DateTime.utc(2026, 10, 19, 13)),
        );
      await tester.pumpAndSettle();
      expect(bannerText(tester), '2 nuove richieste');

      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(byKey('inbox-list-fresh').hitTestable(), findsOneWidget);
      expect(byKey('request-second').hitTestable(), findsOneWidget);
      expect(byKey('request-arrived').hitTestable(), findsOneWidget);
      expect(byKey('request-visto').hitTestable(), findsNothing);
    });
  });

  testWidgets('varios pedidos con el detalle de otro abierto (sin hoja de reserva): «Apri» va a la bandeja', (
    tester,
  ) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      location: '/richieste/req-1',
    );
    app.requests
      ..insertFromRealtime(arrived)
      ..insertFromRealtime(
        buildRequest(id: 'second', name: 'Anna Verdi', createdAt: DateTime.utc(2026, 10, 19, 13)),
      );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-request-banner-open')));
    await tester.pumpAndSettle();
    expect(find.byType(RequestDetailScreen), findsNothing);
    expect(find.byType(InboxScreen), findsOneWidget);
  });

  group('con una hoja «Conferma prenotazione» abierta', () {
    final monday = CalendarDate(2026, 11, 23);
    // El pedido de la hoja (ya visto: está en «Viste»).
    final booked = buildRequest(
      weeks: 4,
      preferredDate: monday,
      estimate: fourWeeksEstimate,
      seenAt: testNow,
      phone: '+39 333 123 4567',
    );
    ChefRequest incoming(String id, String name, int hour) =>
        buildRequest(id: id, name: name, createdAt: DateTime.utc(2026, 10, 19, hour));
    Finder byKey(String key) => find.byKey(ValueKey(key));

    Future<ChefApp> openSheet(WidgetTester tester, {FakeBookingsRepository? bookings}) async {
      final requests = bookings?.requests ?? FakeChefRequestsRepository([booked]);
      final app = await pumpChefApp(
        tester,
        requests: requests,
        bookings: bookings,
        location: '/richieste/req-1',
      );
      await tester.tap(byKey('action-confirm-booking'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      return app;
    }

    // go reemplaza toda la pila sin pasar por el PopScope de la hoja: se
    // perdía la pantalla final con el WhatsApp (la reserva quedaba guardada
    // y ninguna otra parte de la app arma ese mensaje).
    testWidgets('dos pedidos llegan mientras se manda la confirmación: «Apri» abre el más reciente encima y, '
        'al volver, está la reserva confirmada con el WhatsApp', (tester) async {
      final requests = FakeChefRequestsRepository([booked]);
      final bookings = FakeBookingsRepository(requests: requests)..pendingConfirm = Completer<void>();
      final app = await openSheet(tester, bookings: bookings);
      await tester.enterText(byKey('booking-price'), '560');
      await tester.pumpAndSettle();
      await tester.tap(byKey('booking-confirm'));
      await tester.pump();
      expect(find.text('Conferma in corso…'), findsOneWidget);

      app.requests
        ..insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13))
        ..insertFromRealtime(incoming('req-9', 'Anna Verdi', 14));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(bannerText(tester), '2 nuove richieste');
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);
      expect(find.byType(ConfirmBookingScreen, skipOffstage: false), findsOneWidget);
      expect(find.byType(InboxScreen), findsNothing);

      bookings.pendingConfirm!.complete();
      await tester.pumpAndSettle();
      expect(bookings.confirmations, hasLength(1));
      expect(requests.requests['req-1']!.status, RequestStatus.accepted);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Prenotazione confermata'), findsOneWidget);
      expect(byKey('booking-whatsapp').hitTestable(), findsOneWidget);
      await tester.tap(byKey('booking-whatsapp'));
      await tester.pumpAndSettle();
      expect(app.launcher.launched.single.host, 'wa.me');
    });

    testWidgets('sin mandar todavía: «Apri» con varios pedidos no la descarta y, al volver, sigue lo escrito', (
      tester,
    ) async {
      final app = await openSheet(tester);
      await tester.ensureVisible(byKey('booking-price'));
      await tester.enterText(byKey('booking-price'), '600');
      await tester.pumpAndSettle();

      app.requests
        ..insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13))
        ..insertFromRealtime(incoming('req-9', 'Anna Verdi', 14));
      await tester.pumpAndSettle();
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(tester.widget<TextField>(byKey('booking-price')).controller!.text, '600');
    });

    testWidgets('abierta con un enlace directo (/gestione/ recargada en la hoja): «Apri» con varios no la saca', (
      tester,
    ) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([booked]),
        location: '/richieste/req-1/prenota',
      );
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      app.requests
        ..insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13))
        ..insertFromRealtime(incoming('req-9', 'Anna Verdi', 14));
      await tester.pumpAndSettle();
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
    });

    testWidgets('tapada por un pedido abierto desde el aviso, «Apri» con varios tampoco la saca', (tester) async {
      final app = await openSheet(tester);
      await tester.ensureVisible(byKey('booking-price'));
      await tester.enterText(byKey('booking-price'), '600');
      await tester.pumpAndSettle();

      // Un pedido: «Apri» lo abre encima de la hoja.
      app.requests.insertFromRealtime(incoming('req-7', 'Luca Neri', 12));
      await tester.pumpAndSettle();
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Luca Neri'), findsOneWidget);

      // Llegan dos más con ese pedido a la vista.
      app.requests
        ..insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13))
        ..insertFromRealtime(incoming('req-9', 'Anna Verdi', 14));
      await tester.pumpAndSettle();
      expect(bannerText(tester), '2 nuove richieste');
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Luca Neri'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(tester.widget<TextField>(byKey('booking-price')).controller!.text, '600');
    });
  });

  // «Apri» con varios pedidos haría go a la bandeja y se llevaría lo escrito:
  // con «Nuova prenotazione» en la pila (el elegir, el formulario o la hoja a
  // mano), abre el más reciente encima.
  group('con «Nuova prenotazione» abierta', () {
    final chiara = buildClient(id: 'c-chiara', name: 'Chiara Rossi', phone: '340 111 2233');
    ChefRequest incoming(String id, String name, int hour) =>
        buildRequest(id: id, name: name, createdAt: DateTime.utc(2026, 10, 19, hour));
    Finder byKey(String key) => find.byKey(ValueKey(key));

    Future<ChefApp> openPicker(WidgetTester tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        clients: FakeClientsRepository([chiara]),
        location: '/richieste',
      );
      await tester.tap(byKey('inbox-tab-bookings'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('inbox-new-booking'));
      await tester.pumpAndSettle();
      return app;
    }

    Future<void> openNewestFromBanner(WidgetTester tester, ChefApp app) async {
      app.requests
        ..insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13))
        ..insertFromRealtime(incoming('req-9', 'Anna Verdi', 14));
      await tester.pumpAndSettle();
      expect(bannerText(tester), '2 nuove richieste');
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }

    testWidgets('el elegir con una búsqueda escrita', (tester) async {
      final app = await openPicker(tester);
      await tester.enterText(byKey('client-search'), 'chiara');
      await tester.pumpAndSettle();
      await openNewestFromBanner(tester, app);
      expect(find.byType(NewBookingClientScreen), findsOneWidget);
      expect(
        tester.widget<TextField>(byKey('client-search')).controller!.text,
        'chiara',
      );
    });

    testWidgets('el formulario con un nombre escrito', (tester) async {
      final app = await openPicker(tester);
      await tester.tap(byKey('new-booking-new-client'));
      await tester.pumpAndSettle();
      await tester.enterText(byKey('new-client-name'), 'Giulia Rossi');
      await tester.pumpAndSettle();
      await openNewestFromBanner(tester, app);
      expect(find.byType(NewClientScreen), findsOneWidget);
      expect(
        tester.widget<TextField>(byKey('new-client-name')).controller!.text,
        'Giulia Rossi',
      );
    });

    testWidgets('la hoja a mano con el precio escrito', (tester) async {
      final app = await openPicker(tester);
      await tester.tap(byKey('client-c-chiara'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(byKey('booking-price'));
      await tester.enterText(byKey('booking-price'), '560');
      await tester.pumpAndSettle();
      await openNewestFromBanner(tester, app);
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(tester.widget<TextField>(byKey('booking-price')).controller!.text, '560');
    });
  });

  // La hoja «Rinnova» (cuelga de la ficha de la sesión) abierta desde Hoy:
  // «Apri» con varios pedidos tampoco la saca.
  group('con la hoja «Rinnova» abierta', () {
    Finder byKey(String key) => find.byKey(ValueKey(key));
    ChefRequest incoming(String id, String name, int hour) =>
        buildRequest(id: id, name: name, createdAt: DateTime.utc(2026, 10, 19, hour));

    testWidgets('con el precio cambiado: «Apri» con varios abre el más reciente encima y, al volver, sigue lo escrito; al cerrarla, Hoy', (
      tester,
    ) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        sessions: FakeSessionsRepository(buildBooking()),
      );
      expect(find.byType(TodayScreen), findsOneWidget);
      final router = app.container.read(routerProvider);
      unawaited(router.push(AppRoutes.sessionRenew(sessionId(4))));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(bookingOrSessionInStack(router), isTrue);
      await tester.ensureVisible(byKey('booking-price'));
      await tester.enterText(byKey('booking-price'), '600');
      await tester.pumpAndSettle();

      app.requests
        ..insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13))
        ..insertFromRealtime(incoming('req-9', 'Anna Verdi', 14));
      await tester.pumpAndSettle();
      expect(bannerText(tester), '2 nuove richieste');
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);
      expect(find.byType(InboxScreen), findsNothing);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(tester.widget<TextField>(byKey('booking-price')).controller!.text, '600');

      await tester.tap(byKey('booking-close'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsNothing);
      expect(find.byType(TodayScreen), findsOneWidget);
    });
  });

  group('con la ficha de una sesión y su hoja «Sposta»', () {
    // La reserva de prueba: miércoles 25/11, 2/12, 9/12 y 16/12. Se mueve la
    // semana 2 (2/12) al jueves 3/12.
    Finder byKey(String key) => find.byKey(ValueKey(key));
    Finder snackBarAction(String label) =>
        find.descendant(of: find.byType(SnackBar), matching: find.text(label));
    ChefRequest incoming(String id, String name, int hour) =>
        buildRequest(id: id, name: name, createdAt: DateTime.utc(2026, 10, 19, hour));

    /// La ficha de la semana 2 y, desde «Sposta», la hoja con el 3/12.
    Future<ChefApp> openMoveSheet(WidgetTester tester, FakeSessionsRepository sessions) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
        sessions: sessions,
        location: '/sessioni/${sessionId(2)}',
      );
      await tester.tap(byKey('session-move'));
      await tester.pumpAndSettle();
      final picker = find.byType(DatePickerDialog);
      await tester.tap(find.descendant(of: picker, matching: find.text('3')).first);
      await tester.pumpAndSettle();
      final ok = MaterialLocalizations.of(tester.element(picker)).okButtonLabel;
      await tester.tap(find.descendant(of: picker, matching: find.text(ok)));
      await tester.pumpAndSettle();
      expect(find.byType(MoveSessionScreen), findsOneWidget);
      return app;
    }

    testWidgets('un pedido llega mientras se mueve: «Apri» lo abre encima, la hoja no lo cierra al terminar y, '
        'al volver, la ficha ofrece «Annulla»', (tester) async {
      final sessions = FakeSessionsRepository(buildBooking())..pendingMove = Completer<void>();
      final app = await openMoveSheet(tester, sessions);
      await tester.tap(byKey('move-confirm'));
      await tester.pump();

      app.requests.insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi');
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.widgetWithText(AppBar, 'Marco Bianchi'), findsOneWidget);

      sessions.pendingMove!.complete();
      await tester.pumpAndSettle();
      expect(sessions.moves.single.date, CalendarDate(2026, 12, 3));
      // Movida con el pedido encima: el pedido sigue abierto.
      expect(find.widgetWithText(AppBar, 'Marco Bianchi'), findsOneWidget);

      // Al volver, la hoja se cierra y la ficha ofrece «Annulla».
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(MoveSessionScreen), findsNothing);
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(find.text('Sessione spostata a gio 3 dic, arrivo alle 10:00.'), findsOneWidget);
      await tester.tap(snackBarAction('Annulla'));
      await tester.pumpAndSettle();
      expect(sessions.moves.last.date, CalendarDate(2026, 12, 2));
    });

    // go reemplaza toda la pila: sacaba la hoja a medio mover (sin pasar por
    // su PopScope) y la ficha, y con ellas el resultado y su «Annulla».
    testWidgets('dos pedidos llegan mientras se mueve: «Apri» abre encima el más reciente (no la bandeja) y, '
        'al volver, la ficha ofrece «Annulla»', (tester) async {
      final sessions = FakeSessionsRepository(buildBooking())..pendingMove = Completer<void>();
      final app = await openMoveSheet(tester, sessions);
      await tester.tap(byKey('move-confirm'));
      await tester.pump();

      app.requests
        ..insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13))
        ..insertFromRealtime(incoming('req-9', 'Anna Verdi', 14));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(bannerText(tester), '2 nuove richieste');
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);
      expect(find.byType(InboxScreen), findsNothing);
      expect(find.byType(MoveSessionScreen, skipOffstage: false), findsOneWidget);

      sessions.pendingMove!.complete();
      await tester.pumpAndSettle();
      expect(sessions.moves.single.date, CalendarDate(2026, 12, 3));
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(find.text('Sessione spostata a gio 3 dic, arrivo alle 10:00.'), findsOneWidget);
      expect(snackBarAction('Annulla'), findsOneWidget);
    });

    testWidgets('sin mandar todavía: «Apri» con varios no saca la hoja y, al volver, sigue la fecha elegida', (
      tester,
    ) async {
      final sessions = FakeSessionsRepository(buildBooking());
      final app = await openMoveSheet(tester, sessions);
      app.requests
        ..insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13))
        ..insertFromRealtime(incoming('req-9', 'Anna Verdi', 14));
      await tester.pumpAndSettle();
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(MoveSessionScreen), findsOneWidget);
      expect(find.text('giovedì 3 dicembre 2026'), findsOneWidget);
      await tester.tap(byKey('move-confirm'));
      await tester.pumpAndSettle();
      expect(sessions.moves.single.date, CalendarDate(2026, 12, 3));
      expect(find.byType(CookingSessionScreen), findsOneWidget);
    });

    // Con la ficha a la vista el aviso hoy no aparece (la ficha tiene su
    // propio ScaffoldMessenger): la regla se mira directo.
    testWidgets('la ficha cuenta como la hoja de reserva: por enlace directo, con su hoja o tapada por un pedido', (
      tester,
    ) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
        sessions: FakeSessionsRepository(buildBooking()),
      );
      final router = app.container.read(routerProvider);
      Future<bool> at(String location) async {
        app.go(location);
        await tester.pumpAndSettle();
        return bookingOrSessionInStack(router);
      }

      expect(await at('/agenda'), isFalse);
      expect(await at('/richieste/req-1'), isFalse);
      expect(await at('/sessioni/${sessionId(2)}'), isTrue);
      expect(await at('/sessioni/${sessionId(2)}/sposta?data=2026-12-03'), isTrue);

      // Abierta desde la agenda y tapada por un pedido abierto desde el aviso.
      expect(await at('/agenda'), isFalse);
      unawaited(router.push('/sessioni/${sessionId(2)}'));
      await tester.pumpAndSettle();
      unawaited(router.push('/richieste/req-1'));
      await tester.pumpAndSettle();
      expect(find.byType(RequestDetailScreen), findsOneWidget);
      expect(bookingOrSessionInStack(router), isTrue);
    });
  });

  group('desde la Agenda (el recorrido del teléfono: día, sesión, ficha)', () {
    // La reserva de prueba empieza el miércoles 21/10 (hoy: lunes 19/10).
    final wednesday = CalendarDate(2026, 10, 21);
    Finder byKey(String key) => find.byKey(ValueKey(key));
    final navBar = byKey('chef-nav-bar');
    ChefRequest incoming(String id, String name, int hour) =>
        buildRequest(id: id, name: name, createdAt: DateTime.utc(2026, 10, 19, hour));

    /// La Agenda con el miércoles 21/10 elegido y, desde ahí, la ficha de su
    /// sesión (la semana 1).
    Future<ChefApp> openSessionFromAgenda(WidgetTester tester, FakeSessionsRepository sessions) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
        sessions: sessions,
        location: '/agenda',
        // Alto: el día y su sesión a la vista sin desplazar.
        size: const Size(400, 2000),
      );
      await tester.tap(byKey('agenda-day-2026-10-21'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('session-${sessionId(1)}'));
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      return app;
    }

    /// La Agenda, con la barra de navegación y Agenda elegida.
    void expectAgendaWithBar(WidgetTester tester) {
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(navBar.hitTestable(), findsOneWidget);
      expect(tester.widget<NavigationBar>(navBar).selectedIndex, 2);
    }

    // Sobre la ficha el aviso no sale: tiene su propio ScaffoldMessenger (el
    // del «Annulla» después de mover). Aparece al volver (ver README).
    testWidgets('con la ficha a la vista el aviso no sale; al volver a la Agenda está y «Apri» abre el pedido', (
      tester,
    ) async {
      final app = await openSessionFromAgenda(tester, FakeSessionsRepository(buildBooking(first: wednesday)));
      app.requests.insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13));
      await tester.pumpAndSettle();
      expect(find.byKey(banner), findsNothing);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expectAgendaWithBar(tester);
      expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi');
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Marco Bianchi'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expectAgendaWithBar(tester);
    });

    testWidgets('mientras se mueve llegan dos pedidos: «Apri» desde «Sposta» abre encima el más reciente; al terminar '
        'y volver, la ficha ofrece «Annulla» y, al volver, la Agenda sigue con la barra y el día elegido', (
      tester,
    ) async {
      final sessions = FakeSessionsRepository(buildBooking(first: wednesday))..pendingMove = Completer<void>();
      final app = await openSessionFromAgenda(tester, sessions);
      // «Sposta»: el jueves 22/10 en el calendario.
      await tester.tap(byKey('session-move'));
      await tester.pumpAndSettle();
      final picker = find.byType(DatePickerDialog);
      await tester.tap(find.descendant(of: picker, matching: find.text('22')).first);
      await tester.pumpAndSettle();
      final ok = MaterialLocalizations.of(tester.element(picker)).okButtonLabel;
      await tester.tap(find.descendant(of: picker, matching: find.text(ok)));
      await tester.pumpAndSettle();
      expect(find.byType(MoveSessionScreen), findsOneWidget);

      await tester.tap(byKey('move-confirm'));
      await tester.pump();
      app.requests
        ..insertFromRealtime(incoming('req-8', 'Marco Bianchi', 13))
        ..insertFromRealtime(incoming('req-9', 'Anna Verdi', 14));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(bannerText(tester), '2 nuove richieste');
      await tester.tap(byKey('new-request-banner-open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);
      expect(find.byType(MoveSessionScreen, skipOffstage: false), findsOneWidget);

      sessions.pendingMove!.complete();
      await tester.pumpAndSettle();
      expect(sessions.moves.single.date, CalendarDate(2026, 10, 22));
      expect(find.widgetWithText(AppBar, 'Anna Verdi'), findsOneWidget);

      // Al volver, la hoja se cierra y la ficha ofrece «Annulla».
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(MoveSessionScreen), findsNothing);
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(SnackBar), matching: find.text('Annulla')));
      await tester.pumpAndSettle();
      expect(sessions.moves.last.date, wednesday);

      // La Agenda, con el día que estaba elegido y la sesión de vuelta ahí.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expectAgendaWithBar(tester);
      expect(find.text('mercoledì 21 ottobre 2026'), findsOneWidget);
      expect(byKey('session-${sessionId(1)}'), findsOneWidget);
    });
  });

  // Como la ficha, el editor tiene su propio ScaffoldMessenger (ver README).
  testWidgets('sobre el editor de platos el aviso no sale; al volver a Piatti, sí', (tester) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      location: '/altro/piatti',
    );
    app.go('/altro/piatti/nuovo');
    await tester.pumpAndSettle();
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
    app.requests.insertFromRealtime(arrived);
    await tester.pumpAndSettle();
    expect(find.byKey(banner), findsNothing);

    // El editor tiene su propio botón de volver (no un BackButton): se
    // deshabilita mientras traduce o guarda.
    await tester.tap(find.byKey(const ValueKey('recipe-back')));
    await tester.pumpAndSettle();
    expect(find.byType(RecipesScreen), findsOneWidget);
    expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi');
  });

  testWidgets('al reconectar avisa lo que llegó sin conexión', (tester) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
    );
    app.requests.emitRealtime(const RealtimeConnected());
    await tester.pumpAndSettle();
    app.requests
      ..emitRealtime(const RealtimeDisconnected())
      ..insertSilently(arrived)
      ..emitRealtime(const RealtimeConnected());
    await tester.pumpAndSettle();

    expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi');
  });

  testWidgets('abrir el pedido desde la lista cierra su aviso', (tester) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      location: '/richieste',
    );
    app.requests.insertFromRealtime(arrived);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('request-arrived')));
    await tester.pumpAndSettle();
    expect(find.byKey(banner), findsNothing);
  });

  testWidgets('en español', (tester) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      deviceLocales: const [Locale('es', 'ES')],
    );
    app.requests.insertFromRealtime(arrived);
    await tester.pumpAndSettle();
    expect(bannerText(tester), 'Nueva solicitud de Marco Bianchi');
    expect(find.text('Abrir'), findsOneWidget);
  });

  // Pestaña «Menù» de la web: el aviso dice cuántos platos eligió.
  group('con platos elegidos en la web', () {
    final withMenu = buildRequest(
      id: 'arrived',
      name: 'Marco Bianchi',
      createdAt: DateTime.utc(2026, 10, 19, 12),
      wishes: const ['dish-1', 'dish-2'],
    );

    testWidgets('el aviso lo menciona, con cuántos platos', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
      );
      app.requests.insertFromRealtime(withMenu);
      await tester.pumpAndSettle();
      expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi, con 2 piatti scelti dal menù');
    });

    testWidgets('un solo plato', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
      );
      app.requests.insertFromRealtime(withMenu.copyWith(wishes: const ['dish-1']));
      await tester.pumpAndSettle();
      expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi, con 1 piatto scelto dal menù');
    });

    testWidgets('varios pedidos: cuántos traen menú', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
      );
      app.requests
        ..insertFromRealtime(withMenu)
        ..insertFromRealtime(
          buildRequest(id: 'second', name: 'Anna Verdi', createdAt: DateTime.utc(2026, 10, 19, 13)),
        );
      await tester.pumpAndSettle();
      expect(bannerText(tester), '2 nuove richieste (1 con menù)');
    });

    testWidgets('en español', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
        deviceLocales: const [Locale('es', 'ES')],
      );
      app.requests.insertFromRealtime(withMenu);
      await tester.pumpAndSettle();
      expect(bannerText(tester), 'Nueva solicitud de Marco Bianchi, con 2 platos elegidos del menú');
    });
  });
}

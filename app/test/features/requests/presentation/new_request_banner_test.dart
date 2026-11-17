// Aviso emergente en tiempo real: "Nuova richiesta da …" con botón para
// abrirla, desde cualquier pantalla de la cocinera. Con una hoja de reserva
// abierta (o tapada por otro pedido), «Apri» nunca la saca.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';

import '../../../support/chef_app.dart';
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

  group('con la hoja «Sposta» de una sesión', () {
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
}

// La hoja «Rinnova prenotazione» en la app, abierta encima de Hoy
// (/sessioni/<id>/rinnova, como desde su botón): el encabezado con la última
// sesión (y, si corresponde, la semana movida o el otro teléfono del pedido),
// las fechas desde la última viva + 7 con los feriados, la hora, los minutos
// y el precio de la reserva ya puestos, «Controllo le date…» mientras corre
// el primer dryRun, la confirmación con clientId y «Fatto», que vuelve a Hoy.
// Con una respuesta perdida no se cierra hasta reintentar; los estados antes
// de la hoja; y, a 375×667, la acción principal en el tercio inferior.
// "Hoy": martes 15/12/2026 a las 8:00 en Roma, salvo donde se dice otra
// cosa. La reserva de prueba: miércoles 25/11, 2/12, 9/12 y 16/12 a las
// 10:00, 180 min, 4 × 140 €.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/today/presentation/today_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';
import '../../../support/text_input_guard.dart';

/// intl separa el número del € con un espacio duro.
const String _nbsp = ' ';

void main() {
  final morning = DateTime.utc(2026, 12, 15, 7);

  late int keys;
  setUp(() => keys = 0);

  Finder byKey(String key) => find.byKey(ValueKey(key));
  String textOf(WidgetTester tester, String key) =>
      plainSpaces(tester.widget<Text>(byKey(key)).data!);
  FilledButton confirmButton(WidgetTester tester) =>
      tester.widget<FilledButton>(byKey('booking-confirm'));
  Icon weekIcon(WidgetTester tester, int index) => tester.widget<Icon>(
    find.descendant(
      of: byKey('booking-week-$index'),
      matching: find.byType(Icon),
    ).first,
  );

  /// Hoy con las sesiones de [sessions] (por defecto, la reserva de prueba)
  /// y, encima, la hoja «Rinnova» de la sesión [n] (push, como su botón). Con
  /// [settle] en false no espera a que se asiente (una rueda que gira).
  Future<ChefApp> openRenewal(
    WidgetTester tester, {
    FakeSessionsRepository? sessions,
    int n = 4,
    void Function(FakeBookingsRepository bookings)? configure,
    DateTime? now,
    Size size = const Size(400, 900),
    bool settle = true,
  }) async {
    final requests = FakeChefRequestsRepository(const []);
    final clients = FakeClientsRepository();
    final bookings = FakeBookingsRepository(requests: requests, clients: clients);
    configure?.call(bookings);
    final app = await pumpChefApp(
      tester,
      requests: requests,
      clients: clients,
      bookings: bookings,
      sessions: sessions ?? FakeSessionsRepository(buildBooking()),
      clock: () => now ?? morning,
      size: size,
      overrides: [newIdProvider.overrideWithValue(() => 'key-${++keys}')],
    );
    expect(find.byType(TodayScreen), findsOneWidget);
    unawaited(
      app.container.read(routerProvider).push(AppRoutes.sessionRenew(sessionId(n))),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
    return app;
  }

  testWidgets('lo que copia «Rinnova»: 4 semanas desde el 23/12 a las 10:00, 180 min y 560 € ya puestos; el 6/1 avisa la Epifania', (tester) async {
    await openRenewal(tester);
    expect(find.byType(ConfirmBookingScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Rinnova prenotazione'), findsOneWidget);
    final sheet = find.byType(ConfirmBookingScreen);
    expect(find.descendant(of: sheet, matching: find.text('Giulia Rossi')), findsOneWidget);
    expect(textOf(tester, 'booking-subtitle'), 'Rinnovo · ultima sessione mer 16 dic');
    expect(byKey('booking-renewal-moved'), findsNothing);
    expect(byKey('booking-renewal-other-phone'), findsNothing);
    expect(textOf(tester, 'booking-weeks-value'), '4');
    for (final (i, date) in ['mer 23 dic', 'mer 30 dic', 'mer 6 gen', 'mer 13 gen'].indexed) {
      expect(find.text('Settimana ${i + 1} · $date'), findsOneWidget);
    }
    expect(textOf(tester, 'booking-week-2-status'), 'Festività: Epifania');
    expect(weekIcon(tester, 2).icon, Icons.warning_amber_outlined);
    expect(textOf(tester, 'booking-week-0-status'), 'Libero');
    expect(tester.widget<ChoiceChip>(byKey('booking-start-10:00')).selected, isTrue);
    await tester.ensureVisible(byKey('booking-cook-value'));
    expect(textOf(tester, 'booking-cook-value'), '180 min');
    expect(find.text('Come nella prenotazione precedente.'), findsOneWidget);
    expect(textOf(tester, 'booking-adults-value'), '2');
    expect(textOf(tester, 'booking-kids-value'), '2');
    expect(textOf(tester, 'booking-days-value'), '5');
    expect(tester.widget<FilterChip>(byKey('booking-meal-dinner')).selected, isTrue);
    expect(tester.widget<ChoiceChip>(byKey('booking-locale-it')).selected, isTrue);
    expect(tester.widget<TextField>(byKey('booking-price')).controller!.text, '560');
    expect(
      textOf(tester, 'booking-summary'),
      'Servizio 560,00$_nbsp€ · 140,00$_nbsp€ a settimana · arrivo 10:00',
    );
    expect(find.text('Conferma 4 settimane'), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNotNull);
    expectReadableInputs(tester);
  });

  testWidgets('mientras corre el primer dryRun, la barra dice «Controllo le date…» (al lector de pantalla también)', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await openRenewal(
      tester,
      configure: (b) => b.pendingChecks = Completer<void>(),
      settle: false,
    );
    expect(textOf(tester, 'booking-checking'), 'Controllo le date…');
    expect(
      tester.getSemantics(byKey('booking-checking')),
      isSemantics(isLiveRegion: true),
    );
    expect(confirmButton(tester).onPressed, isNull);

    app.bookings.pendingChecks!.complete();
    await tester.pumpAndSettle();
    expect(byKey('booking-checking'), findsNothing);
    expect(byKey('booking-summary'), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNotNull);
    semantics.dispose();
  });

  testWidgets('«Conferma 4 settimane» manda el cuerpo de la renovación (clientId); el WhatsApp va a la ficha y «Fatto» vuelve a Hoy', (tester) async {
    final app = await openRenewal(tester);
    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Prenotazione confermata'), findsOneWidget);
    expect(app.bookings.confirmations.single.toBody(), {
      'clientId': testClientId,
      'type': 'week',
      'household': {
        'adults': 2,
        'kids': 2,
        'days': 5,
        'meals': ['dinner'],
      },
      'locale': 'it',
      'dates': ['2026-12-23', '2026-12-30', '2027-01-06', '2027-01-13'],
      'start': '10:00',
      'cookMinutes': 180,
      'portions': 20,
      'groceriesEstCents': 6300,
      'serviceTotalCents': 56000,
      'requestKey': 'key-1',
      'dryRun': false,
    });

    await tester.tap(byKey('booking-whatsapp'));
    await tester.pumpAndSettle();
    final whatsApp = app.launcher.launched.single;
    expect(whatsApp.path, '/393331234567');
    expect(whatsApp.queryParameters['text'], startsWith('Ciao Giulia, sono Evelyn di Radici.'));

    await tester.tap(byKey('booking-done-close'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmBookingScreen), findsNothing);
    expect(find.byType(TodayScreen), findsOneWidget);
  });

  testWidgets('sin respuesta al confirmar: la hoja no se cierra hasta reintentar, y el reintento no duplica', (tester) async {
    final app = await openRenewal(
      tester,
      configure: (b) => b.loseNextConfirmResponse = true,
    );
    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();
    expect(
      textOf(tester, 'booking-retry-keeps-open'),
      'La scheda resta aperta finché non arriva una risposta: così la prenotazione non si duplica.',
    );
    expect(tester.widget<IconButton>(byKey('booking-close')).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmBookingScreen), findsOneWidget);

    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();
    final sent = app.bookings.confirmations;
    expect(sent, hasLength(2));
    expect(sent.last, sent.first);
    expect(app.bookings.savedByKey, hasLength(1));
    expect(byKey('booking-done-duplicate'), findsOneWidget);
  });

  testWidgets('la última semana movida al viernes 18/12 a las 11:00: lo dice el encabezado, las fechas siguen a esa semana y el 25/12 y el 1/1 avisan los feriados', (tester) async {
    final booking = buildBooking();
    booking[3] = booking[3].copyWith(
      date: CalendarDate(2026, 12, 18),
      start: const ClockTime.hm(11, 0),
    );
    await openRenewal(tester, sessions: FakeSessionsRepository(booking));
    expect(
      textOf(tester, 'booking-renewal-moved'),
      "L'ultima settimana era stata spostata: giorno e ora vengono da quella.",
    );
    expect(find.text('Settimana 1 · ven 25 dic'), findsOneWidget);
    expect(textOf(tester, 'booking-week-0-status'), 'Festività: Natale');
    expect(textOf(tester, 'booking-week-1-status'), 'Festività: Capodanno');
    expect(tester.widget<ChoiceChip>(byKey('booking-start-11:00')).selected, isTrue);
  });

  testWidgets('desde Hoy el día +7 a las 18:00: la semana 1 avisa que la llegada ya pasó y se puede confirmar', (tester) async {
    // Martes 20/10 a 10/11 a las 10:00; hoy, martes 17/11 a las 18:00.
    await openRenewal(
      tester,
      sessions: FakeSessionsRepository(buildBooking(first: CalendarDate(2026, 10, 20))),
      now: DateTime.utc(2026, 11, 17, 17),
    );
    expect(find.text('Settimana 1 · mar 17 nov'), findsOneWidget);
    expect(
      textOf(tester, 'booking-week-0-status'),
      "È oggi e l'ora di arrivo è già passata.",
    );
    expect(weekIcon(tester, 0).icon, Icons.warning_amber_outlined);
    expect(confirmButton(tester).onPressed, isNotNull);
  });

  testWidgets('un pedido renovado con otro teléfono: el encabezado lo dice y el WhatsApp va al de la ficha', (tester) async {
    final booking = [
      for (final session in buildBooking())
        session.copyWith(
          request: session.request!.copyWith(
            client: session.request!.client.copyWith(
              contactPhone: '+34 612 345 678',
            ),
          ),
        ),
    ];
    final app = await openRenewal(tester, sessions: FakeSessionsRepository(booking));
    expect(
      textOf(tester, 'booking-renewal-other-phone'),
      'Nella richiesta precedente il numero era +34 612 345 678: il WhatsApp va a quello della scheda.',
    );
    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('booking-whatsapp'));
    await tester.pumpAndSettle();
    expect(app.launcher.launched.single.path, '/393331234567');
  });

  testWidgets('más de 300 minutos se copian: «+» deshabilitado y «−» los lleva a 300', (tester) async {
    await openRenewal(
      tester,
      sessions: FakeSessionsRepository([
        for (final session in buildBooking()) session.copyWith(cookMinutes: 360),
      ]),
    );
    await tester.ensureVisible(byKey('booking-cook-value'));
    expect(textOf(tester, 'booking-cook-value'), '360 min');
    expect(
      tester.widget<IconButton>(byKey('booking-cook-increment')).onPressed,
      isNull,
    );
    await tester.tap(byKey('booking-cook-decrement'));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'booking-cook-value'), '300 min');
  });

  group('antes de la hoja', () {
    testWidgets('leyendo la reserva: la rueda con el título', (tester) async {
      final sessions = FakeSessionsRepository(buildBooking());
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        sessions: sessions,
        clock: () => morning,
      );
      sessions.pendingFetch = Completer<void>();
      unawaited(
        app.container.read(routerProvider).push(AppRoutes.sessionRenew(sessionId(4))),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(byKey('booking-loading'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Rinnova prenotazione'), findsOneWidget);
      sessions.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(textOf(tester, 'booking-weeks-value'), '4');
    });

    testWidgets('si no se pudo leer: el mensaje y «Riprova»', (tester) async {
      final sessions = FakeSessionsRepository(buildBooking());
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        sessions: sessions,
        clock: () => morning,
      );
      sessions.fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
      unawaited(
        app.container.read(routerProvider).push(AppRoutes.sessionRenew(sessionId(4))),
      );
      await tester.pumpAndSettle();
      final sheet = find.byType(ConfirmBookingScreen);
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(
            'Impossibile caricare la sessione. Controlla la connessione e riprova.',
          ),
        ),
        findsOneWidget,
      );
      sessions.fetchFailure = null;
      await tester.tap(find.descendant(of: sheet, matching: byKey('load-error-retry')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'booking-weeks-value'), '4');
    });

    testWidgets('una sesión que no existe lo dice', (tester) async {
      await openRenewal(tester, n: 9);
      expect(
        textOf(tester, 'booking-session-not-found'),
        'Questa sessione non esiste o non è più disponibile.',
      );
    });

    testWidgets('una reserva que no se puede renovar (una sesión extra) lo dice', (tester) async {
      await openRenewal(
        tester,
        sessions: FakeSessionsRepository([
          buildSession(
            n: 5,
            requestId: 'extra',
            type: RequestType.extra,
            weeks: 1,
            date: CalendarDate(2026, 12, 16),
          ),
        ]),
        n: 5,
      );
      expect(
        textOf(tester, 'booking-renewal-unavailable'),
        'Questa prenotazione non si può rinnovare.',
      );
    });
  });

  testWidgets('a 375×667 «Conferma 4 settimane» queda en el tercio inferior con el resumen arriba, y los contadores miden 48 dp', (tester) async {
    await openRenewal(tester, size: const Size(375, 667));
    final confirm = byKey('booking-confirm');
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.getCenter(confirm).dy, greaterThan(667 * 2 / 3));
    expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
    final summary = byKey('booking-summary');
    expect(summary.hitTestable(), findsOneWidget);
    expect(tester.getRect(summary).bottom, lessThanOrEqualTo(tester.getRect(confirm).top));
    for (final key in [
      'booking-weeks-increment',
      'booking-adults-increment',
      'booking-cook-decrement',
      'booking-locale-es',
    ]) {
      await tester.ensureVisible(byKey(key));
      await tester.pumpAndSettle();
      expect(tester.getSize(byKey(key)).height, greaterThanOrEqualTo(48), reason: key);
    }
    expectReadableInputs(tester);
    expect(tester.takeException(), isNull);
  });
}

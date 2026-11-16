// Agenda con sesiones: un punto por sesión en la celda del mes (y en el texto
// accesible), sus bloques en la tarjeta del día y en la semana con las horas
// de la sesión («Spesa dalle · Arrivo · fino alle»), cada uno abre su ficha;
// los pedidos aceptados ya no se listan por fecha preferida; bloquear un día
// con sesión avisa que no la cancela; deslizar para actualizar las vuelve a
// leer. "Hoy": lunes 19/10/2026 (testNow). La reserva de prueba: miércoles
// 21/10, 28/10, 4/11 y 11/11.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  final wednesday = CalendarDate(2026, 10, 21);

  Finder byKey(String key) => find.byKey(ValueKey(key));
  Finder day(String iso) => byKey('agenda-day-$iso');

  List<CookingSession> booking() => buildBooking(first: wednesday);

  /// La reserva aceptada (con su fecha preferida, el 21/10) y un pedido nuevo
  /// el mismo día.
  FakeChefRequestsRepository requests() => FakeChefRequestsRepository([
    buildRequest(
      id: bookingRequestId,
      name: 'Giulia Rossi',
      preferredDate: wednesday,
      status: RequestStatus.accepted,
      weeks: 4,
    ),
    buildRequest(id: 'nuovo', name: 'Marco Bianchi', preferredDate: wednesday),
  ]);

  Future<ChefApp> openAgenda(
    WidgetTester tester, {
    FakeSessionsRepository? sessions,
    FakeAvailabilityRepository? availability,
    Size size = const Size(400, 2000),
    Locale locale = const Locale('it', 'IT'),
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: requests(),
      sessions: sessions ?? FakeSessionsRepository(booking()),
      availability: availability,
      location: '/agenda',
      size: size,
      deviceLocales: [locale],
    );
    expect(find.byType(AgendaScreen), findsOneWidget);
    return app;
  }

  Future<void> selectDay(WidgetTester tester, String iso) async {
    await tester.tap(day(iso));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'el mes marca los días con sesión; el aceptado ya no cuenta por su fecha preferida',
    (tester) async {
      await openAgenda(tester);

      expect(byKey('agenda-day-sessions-2026-10-21'), findsOneWidget);
      expect(byKey('agenda-day-sessions-2026-10-28'), findsOneWidget);
      expect(byKey('agenda-day-sessions-2026-10-22'), findsNothing);
      // Solo el pedido nuevo: la reserva se ve por su sesión.
      expect(
        tester.widget<Text>(byKey('agenda-day-count-2026-10-21')).data,
        '1',
      );
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          RegExp(r'21 ottobre 2026, 1 sessione, 1 richiesta$'),
        ),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'el día muestra su sesión con las horas (antes que los pedidos) y abre su ficha',
    (tester) async {
      await openAgenda(tester);
      await selectDay(tester, '2026-10-21');

      final block = byKey('session-${sessionId(1)}');
      expect(block, findsOneWidget);
      expect(
        tester.widget<Text>(byKey('session-${sessionId(1)}-times')).data,
        'Spesa dalle 09:15 · Arrivo 10:00 · fino alle 13:00',
      );
      expect(byKey('request-nuovo'), findsOneWidget);
      expect(byKey('request-$bookingRequestId'), findsNothing);
      expect(
        tester.getTopLeft(block).dy,
        lessThan(tester.getTopLeft(byKey('request-nuovo')).dy),
      );
      expect(byKey('agenda-day-empty'), findsNothing);

      await tester.tap(block);
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('session-week')).data,
        'Settimana 1 di 4',
      );

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
    },
  );

  testWidgets(
    'la semana muestra bloques con las horas de cada sesión, y el estado si no está confirmada',
    (tester) async {
      final sessions = FakeSessionsRepository([
        ...booking(),
        buildSession(
          n: 9,
          requestId: 'altra',
          name: 'Sara Colombo',
          date: CalendarDate(2026, 10, 23),
          start: const ClockTime.hm(11, 30),
          cookMinutes: 150,
          status: SessionStatus.held,
        ),
        buildSession(
          n: 8,
          requestId: 'annullata',
          name: 'Luca Neri',
          date: CalendarDate(2026, 10, 22),
          status: SessionStatus.cancelled,
        ),
      ]);
      await openAgenda(tester, sessions: sessions);
      await tester.tap(byKey('agenda-view-week'));
      await tester.pumpAndSettle();

      final wednesdayCard = byKey('agenda-week-day-2026-10-21');
      expect(
        find.descendant(
          of: wednesdayCard,
          matching: find.text(
            'Spesa dalle 09:15 · Arrivo 10:00 · fino alle 13:00',
          ),
        ),
        findsOneWidget,
      );
      final fridayCard = byKey('agenda-week-day-2026-10-23');
      expect(
        find.descendant(
          of: fridayCard,
          matching: find.text(
            'Spesa dalle 10:45 · Arrivo 11:30 · fino alle 14:00',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: fridayCard,
          matching: find.text('In attesa di conferma'),
        ),
        findsOneWidget,
      );
      // La cancelada no se muestra.
      expect(byKey('session-${sessionId(8)}'), findsNothing);

      await tester.tap(byKey('session-${sessionId(9)}'));
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
    },
  );

  testWidgets(
    'un día con sesión avisa que bloquearlo no la cancela, y después de bloquearlo la sesión sigue',
    (tester) async {
      final app = await openAgenda(tester);
      await selectDay(tester, '2026-10-21');

      expect(
        find.text('1 sessione in questo giorno: bloccarlo non la annulla.'),
        findsOneWidget,
      );
      await tester.tap(byKey('availability-block-2026-10-21'));
      await tester.pumpAndSettle();

      expect(app.availability.blocked.keys, [wednesday]);
      expect(
        find.text('1 sessione in questo giorno: bloccarlo non la annulla.'),
        findsOneWidget,
      );
      expect(byKey('session-${sessionId(1)}'), findsOneWidget);
      expect(app.sessions.cancelCalls, isEmpty);
    },
  );

  testWidgets('en la semana también avisa, junto al botón', (tester) async {
    await openAgenda(tester);
    await tester.tap(byKey('agenda-view-week'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: byKey('agenda-week-day-2026-10-21'),
        matching: find.text(
          '1 sessione in questo giorno: bloccarlo non la annulla.',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('el rango a bloquear dice cuántos de sus días tienen sesiones', (
    tester,
  ) async {
    // 600 px: ver el test del rango de agenda_screen_test.
    await openAgenda(tester, size: const Size(600, 900));
    await tester.tap(byKey('agenda-block-range'));
    await tester.pumpAndSettle();
    final picker = find.byType(DateRangePickerDialog);
    Finder pickerDay(String number) =>
        find.descendant(of: picker, matching: find.text(number)).first;
    await tester.tap(pickerDay('20'));
    await tester.pumpAndSettle();
    await tester.tap(pickerDay('30'));
    await tester.pumpAndSettle();
    final save = MaterialLocalizations.of(tester.element(picker))
        .saveButtonLabel;
    await tester.tap(find.descendant(of: picker, matching: find.text(save)));
    await tester.pumpAndSettle();

    expect(
      find.text('2 di questi giorni hanno sessioni: bloccarli non le annulla.'),
      findsOneWidget,
    );
  });

  testWidgets('deslizar para actualizar vuelve a leer las sesiones', (
    tester,
  ) async {
    final app = await openAgenda(tester, size: const Size(400, 900));
    final before = app.sessions.fetchCalls;
    app.sessions.sessions[sessionId(9)] = buildSession(
      n: 9,
      requestId: 'nuova',
      date: CalendarDate(2026, 10, 22),
    );

    await tester.fling(byKey('agenda'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(app.sessions.fetchCalls, before + 1);
    expect(byKey('agenda-day-sessions-2026-10-22'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('si no se pudieron leer las sesiones lo dice, con «Riprova»', (
    tester,
  ) async {
    final sessions = FakeSessionsRepository(booking())
      ..fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
    await openAgenda(tester, sessions: sessions);

    expect(find.text('Impossibile caricare le sessioni.'), findsOneWidget);
    expect(byKey('agenda-day-sessions-2026-10-21'), findsNothing);

    sessions.fetchFailure = null;
    await tester.tap(byKey('sessions-retry'));
    await tester.pumpAndSettle();
    expect(byKey('sessions-load-error'), findsNothing);
    expect(byKey('agenda-day-sessions-2026-10-21'), findsOneWidget);
  });

  testWidgets(
    'una sesión movida desde su ficha aparece en su día nuevo sin volver a leer',
    (tester) async {
      final app = await openAgenda(tester);
      await selectDay(tester, '2026-10-21');
      await tester.tap(byKey('session-${sessionId(1)}'));
      await tester.pumpAndSettle();
      final reads = app.sessions.fetchCalls;

      app.go('/sessioni/${sessionId(1)}/sposta?data=2026-10-22');
      await tester.pumpAndSettle();
      await tester.tap(byKey('move-confirm'));
      await tester.pumpAndSettle();
      app.go('/agenda');
      await tester.pumpAndSettle();

      expect(byKey('agenda-day-sessions-2026-10-21'), findsNothing);
      expect(byKey('agenda-day-sessions-2026-10-22'), findsOneWidget);
      expect(app.sessions.fetchCalls, reads);
    },
  );

  testWidgets(
    'tres sesiones o más: como mucho tres puntos, y el texto accesible las cuenta todas',
    (tester) async {
      final busy = CalendarDate(2026, 10, 27);
      await openAgenda(
        tester,
        sessions: FakeSessionsRepository([
          for (var n = 1; n <= 4; n++)
            buildSession(
              n: n,
              requestId: 'req-$n',
              date: busy,
              start: ClockTime.hm(8 + n, 0),
              cookMinutes: 30,
              shopMinutes: 0,
              gapMinutes: 0,
            ),
        ]),
      );
      final dots = find.descendant(
        of: byKey('agenda-day-sessions-2026-10-27'),
        matching: find.byType(Container),
      );
      expect(dots, findsNWidgets(3));
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          RegExp(r'27 ottobre 2026, 4 sessioni, nessuna richiesta$'),
        ),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
    testWidgets(
      'a 375×667 sin desbordes, con sesiones (${locale.languageCode})',
      (tester) async {
        await openAgenda(tester, size: const Size(375, 667), locale: locale);
        await selectDay(tester, '2026-10-21');
        // Al elegir el día, su sesión queda a la vista sin desplazar a mano.
        expect(byKey('session-${sessionId(1)}').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.drag(byKey('agenda'), const Offset(0, 3000));
        await tester.pumpAndSettle();
        await tester.tap(byKey('agenda-view-week'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}

// Agenda con sesiones: un punto por sesión en la celda del mes (y en el texto
// accesible), sus bloques en la tarjeta del día y en la semana con las horas
// de la sesión («Arrivo · fino alle», sin compra; una vieja en shopping_done,
// sin estado, como una confirmada), cada uno abre su ficha
// (también con el lector de pantalla), que tapa la barra de navegación como
// su hoja «Sposta» (al volver, la Agenda sigue elegida); los pedidos aceptados
// ya no se listan por fecha preferida; bloquear un día con sesión avisa que no
// la cancela (y el rango, si no se pudieron leer, que no se sabe); deslizar
// para actualizar las vuelve a leer, y si falla quedan las que había. "Hoy":
// lunes 19/10/2026 (testNow). La reserva de prueba: miércoles 21/10, 28/10,
// 4/11 y 11/11.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/plain_text.dart';
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
        plainSpaces(
          tester.widget<Text>(byKey('session-${sessionId(1)}-times')).data!,
        ),
        'Arrivo 10:00 · fino alle 13:00',
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
        // De antes del 19/11/2026: guarda 45 min de compra, que no se
        // muestran.
        buildSession(
          n: 9,
          requestId: 'altra',
          name: 'Sara Colombo',
          date: CalendarDate(2026, 10, 23),
          start: const ClockTime.hm(11, 30),
          cookMinutes: 150,
          shopMinutes: 45,
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
          matching: findPlainText('Arrivo 10:00 · fino alle 13:00'),
        ),
        findsOneWidget,
      );
      final fridayCard = byKey('agenda-week-day-2026-10-23');
      expect(
        find.descendant(
          of: fridayCard,
          matching: findPlainText('Arrivo 11:30 · fino alle 14:00'),
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

  /// Abre «Blocca giorni» y elige del día [from] al [to] de octubre.
  Future<void> pickRange(WidgetTester tester, String from, String to) async {
    await tester.tap(byKey('agenda-block-range'));
    await tester.pumpAndSettle();
    final picker = find.byType(DateRangePickerDialog);
    Finder pickerDay(String number) =>
        find.descendant(of: picker, matching: find.text(number)).first;
    await tester.tap(pickerDay(from));
    await tester.pumpAndSettle();
    await tester.tap(pickerDay(to));
    await tester.pumpAndSettle();
    final save = MaterialLocalizations.of(tester.element(picker))
        .saveButtonLabel;
    await tester.tap(find.descendant(of: picker, matching: find.text(save)));
    await tester.pumpAndSettle();
  }

  testWidgets('el rango a bloquear dice cuántos de sus días tienen sesiones', (
    tester,
  ) async {
    // 600 px: ver el test del rango de agenda_screen_test.
    await openAgenda(tester, size: const Size(600, 900));
    await pickRange(tester, '20', '30');

    expect(
      find.text('2 di questi giorni hanno sessioni: bloccarli non le annulla.'),
      findsOneWidget,
    );
    expect(byKey('block-range-sessions-unknown'), findsNothing);
  });

  testWidgets(
    'si las sesiones no se pudieron leer, el rango a bloquear dice que no se sabe (la agenda queda tapada)',
    (tester) async {
      final sessions = FakeSessionsRepository(booking())
        ..fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
      await openAgenda(tester, sessions: sessions, size: const Size(600, 900));
      await pickRange(tester, '20', '30');

      expect(
        find.text(
          'Non è stato possibile verificare se questi giorni hanno sessioni.',
        ),
        findsOneWidget,
      );
      expect(byKey('block-range-sessions'), findsNothing);
    },
  );

  testWidgets(
    'un día con solo una sesión no dice que está vacío; uno sin nada, sí',
    (tester) async {
      await openAgenda(tester);
      // El 28/10: la semana 2 de la reserva, ningún pedido.
      await selectDay(tester, '2026-10-28');
      expect(byKey('session-${sessionId(2)}'), findsOneWidget);
      expect(byKey('agenda-day-empty'), findsNothing);

      await selectDay(tester, '2026-10-22');
      expect(
        find.descendant(
          of: byKey('agenda-day-empty'),
          matching: find.text(
            'Niente per questo giorno: né sessioni né richieste.',
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'con VoiceOver se abre una sesión: la celda del día y el bloque son botones con la acción de tocar',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await openAgenda(tester);

      // En /gestione/, el clic del lector de pantalla solo llega a un nodo
      // con la acción de tocar (excludeSemantics descarta la del InkWell).
      expect(
        tester.getSemantics(day('2026-10-28')),
        isSemantics(isButton: true, hasTapAction: true),
      );
      tester.semantics.tap(
        find.semantics.byLabel(RegExp(r'28 ottobre 2026, 1 sessione')),
      );
      await tester.pumpAndSettle();
      final block = byKey('session-${sessionId(2)}');
      expect(block, findsOneWidget);
      expect(
        tester.getSemantics(block),
        isSemantics(isButton: true, hasTapAction: true),
      );

      tester.semantics.tap(find.semantics.byLabel(RegExp(r'^Giulia Rossi, ')));
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('session-week')).data,
        'Settimana 2 di 4',
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'en la semana, el bloque es un nodo propio: no se funde con el título del día',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await openAgenda(tester);
      await tester.tap(byKey('agenda-view-week'));
      await tester.pumpAndSettle();

      final node = tester.getSemantics(byKey('session-${sessionId(1)}'));
      expect(
        plainSpaces(node.getSemanticsData().label),
        'Giulia Rossi, Arrivo 10:00 · fino alle 13:00',
      );
      expect(node, isSemantics(isButton: true, hasTapAction: true));
      semantics.dispose();
    },
  );

  testWidgets(
    'una vieja en shopping_done se ve como confirmada: su bloque no lleva etiqueta de estado, en el día ni en la semana',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await openAgenda(
        tester,
        sessions: FakeSessionsRepository(
          buildBooking(
            first: wednesday,
            statuses: {1: SessionStatus.shoppingDone},
          ),
        ),
      );
      final block = byKey('session-${sessionId(1)}');
      final status = byKey('session-${sessionId(1)}-status');

      await selectDay(tester, '2026-10-21');
      expect(block, findsOneWidget);
      expect(status, findsNothing);

      await tester.tap(byKey('agenda-view-week'));
      await tester.pumpAndSettle();
      expect(block, findsOneWidget);
      expect(status, findsNothing);
      expect(
        plainSpaces(tester.getSemantics(block).getSemanticsData().label),
        'Giulia Rossi, Arrivo 10:00 · fino alle 13:00',
      );
      semantics.dispose();
    },
  );

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

  testWidgets(
    'deslizar para actualizar: si las sesiones no se pueden leer, quedan las que había y lo dice',
    (tester) async {
      final app = await openAgenda(tester, size: const Size(400, 900));
      app.sessions.fetchFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );

      await tester.fling(byKey('agenda'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.text('Aggiornamento non riuscito. Controlla la connessione.'),
        findsOneWidget,
      );
      expect(byKey('agenda-day-sessions-2026-10-21'), findsOneWidget);
      // No se vació: ni el aviso de que no se pudieron cargar.
      expect(byKey('sessions-load-error'), findsNothing);
    },
  );

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
    'la ficha y la hoja «Sposta» tapan la barra; al volver regresa a la agenda, con la barra y Agenda elegida',
    (tester) async {
      final app = await openAgenda(tester);
      final navBar = byKey('chef-nav-bar');
      expect(tester.widget<NavigationBar>(navBar).selectedIndex, 2);
      await selectDay(tester, '2026-10-21');
      await tester.tap(byKey('session-${sessionId(1)}'));
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(navBar, findsNothing, reason: 'la ficha tapa la barra');

      // «Sposta»: el calendario y, con la fecha, la hoja.
      await tester.tap(byKey('session-move'));
      await tester.pumpAndSettle();
      final picker = find.byType(DatePickerDialog);
      await tester.tap(
        find.descendant(of: picker, matching: find.text('22')).first,
      );
      await tester.pumpAndSettle();
      final ok = MaterialLocalizations.of(tester.element(picker)).okButtonLabel;
      await tester.tap(find.descendant(of: picker, matching: find.text(ok)));
      await tester.pumpAndSettle();
      expect(find.byType(MoveSessionScreen), findsOneWidget);
      expect(navBar, findsNothing, reason: 'la hoja tapa la barra');

      await tester.tap(byKey('move-confirm'));
      await tester.pumpAndSettle();
      expect(app.sessions.moves.single.date, CalendarDate(2026, 10, 22));
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(navBar, findsNothing, reason: 'de vuelta en la ficha, tapada');

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(navBar.hitTestable(), findsOneWidget);
      expect(tester.widget<NavigationBar>(navBar).selectedIndex, 2);
      expect(
        find.descendant(
          of: navBar,
          matching: find.byType(NavigationDestination),
        ),
        findsNWidgets(4),
      );
    },
  );

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

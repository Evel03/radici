// Hoja «Sposta la sessione»: desde la ficha, el calendario y después lo que
// dice el servidor de esa fecha antes de confirmar (libre, un aviso, un
// choque o la semana con otra sesión de la reserva, que ofrece pasarla al
// final), mover y «Annulla» en la ficha. Los campos del calendario y del reloj
// en modo escritura tienen letra de 16 px o más (si no, iOS hace zoom) y la
// acción principal queda en el tercio inferior a 375×667.
// La reserva de prueba: miércoles 25/11, 2/12, 9/12 y 16/12.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/session_fixtures.dart';
import '../../../support/text_input_guard.dart';

void main() {
  final thursday = CalendarDate(2026, 12, 3);

  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(byKey(key)).data!;

  VoidCallback? confirmOf(WidgetTester tester) =>
      tester.widget<FilledButton>(byKey('move-confirm')).onPressed;

  /// La app en [location] con la reserva de prueba (o [sessions]).
  Future<ChefApp> open(
    WidgetTester tester,
    String location, {
    FakeSessionsRepository? sessions,
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
  }) => pumpChefApp(
    tester,
    requests: FakeChefRequestsRepository(const []),
    sessions: sessions ?? FakeSessionsRepository(buildBooking()),
    location: location,
    size: size,
    deviceLocales: [locale],
  );

  /// La hoja de la semana 2 con [date] ya elegida, sobre su ficha.
  Future<ChefApp> openSheet(
    WidgetTester tester, {
    CalendarDate? date,
    FakeSessionsRepository? sessions,
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
  }) async {
    final app = await open(
      tester,
      '/sessioni/${sessionId(2)}',
      sessions: sessions,
      size: size,
      locale: locale,
    );
    app.go(
      '/sessioni/${sessionId(2)}/sposta'
      '${date == null ? '' : '?data=${date.toIso()}'}',
    );
    await tester.pumpAndSettle();
    expect(find.byType(MoveSessionScreen), findsOneWidget);
    return app;
  }

  testWidgets(
    '«Sposta» abre el calendario; con la fecha, la hoja dice cómo queda y mueve; «Annulla» la devuelve',
    (tester) async {
      final app = await open(tester, '/sessioni/${sessionId(2)}');
      await tester.tap(byKey('session-move'));
      await tester.pumpAndSettle();

      final picker = find.byType(DatePickerDialog);
      expect(picker, findsOneWidget);
      expect(
        find.descendant(
          of: picker,
          matching: find.text('Nuova data della sessione'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: picker, matching: find.text('3')).first,
      );
      await tester.pumpAndSettle();
      final ok = MaterialLocalizations.of(tester.element(picker)).okButtonLabel;
      await tester.tap(find.descendant(of: picker, matching: find.text(ok)));
      await tester.pumpAndSettle();

      expect(find.byType(MoveSessionScreen), findsOneWidget);
      expect(
        textOf(tester, 'move-now'),
        'Adesso: mer 2 dic, arrivo alle 10:00',
      );
      expect(find.text('giovedì 3 dicembre 2026'), findsOneWidget);
      expect(textOf(tester, 'move-date-status'), 'Libero');
      expect(app.sessions.checks.single.date, thursday);
      expect(app.sessions.checks.single.start, const ClockTime.hm(10, 0));
      expect(textOf(tester, 'move-summary'), 'gio 3 dic, arrivo alle 10:00');
      expect(find.text('Sposta a gio 3 dic'), findsOneWidget);

      await tester.tap(byKey('move-confirm'));
      await tester.pumpAndSettle();

      expect(app.sessions.moves.single.date, thursday);
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(textOf(tester, 'session-date'), 'giovedì 3 dicembre 2026');
      expect(
        find.text('Sessione spostata a gio 3 dic, arrivo alle 10:00.'),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Annulla'),
        ),
      );
      await tester.pumpAndSettle();
      expect(app.sessions.moves.last.date, CalendarDate(2026, 12, 2));
      expect(app.sessions.moves.last.start, const ClockTime.hm(10, 0));
      expect(textOf(tester, 'session-date'), 'mercoledì 2 dicembre 2026');
      expect(find.text('Spostamento annullato.'), findsOneWidget);
    },
  );

  testWidgets(
    'el aviso de «Annulla» es de esa ficha: no queda en la de otra sesión',
    (tester) async {
      final app = await open(tester, '/sessioni/${sessionId(2)}');
      await tester.tap(byKey('session-move'));
      await tester.pumpAndSettle();
      final picker = find.byType(DatePickerDialog);
      await tester.tap(
        find.descendant(of: picker, matching: find.text('3')).first,
      );
      await tester.pumpAndSettle();
      final ok = MaterialLocalizations.of(tester.element(picker)).okButtonLabel;
      await tester.tap(find.descendant(of: picker, matching: find.text(ok)));
      await tester.pumpAndSettle();
      await tester.tap(byKey('move-confirm'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);

      // go a otra sesión reutiliza la página (misma ruta): el aviso no pasa.
      app.go('/sessioni/${sessionId(3)}');
      await tester.pumpAndSettle();
      expect(textOf(tester, 'session-date'), 'mercoledì 9 dicembre 2026');
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('si «Annulla» falla, avisa con «Riprova»', (tester) async {
    final app = await open(tester, '/sessioni/${sessionId(2)}');
    await tester.tap(byKey('session-move'));
    await tester.pumpAndSettle();
    final picker = find.byType(DatePickerDialog);
    await tester.tap(
      find.descendant(of: picker, matching: find.text('3')).first,
    );
    await tester.pumpAndSettle();
    final ok = MaterialLocalizations.of(tester.element(picker)).okButtonLabel;
    await tester.tap(find.descendant(of: picker, matching: find.text(ok)));
    await tester.pumpAndSettle();
    await tester.tap(byKey('move-confirm'));
    await tester.pumpAndSettle();

    app.sessions.moveFailure = const SessionFailure(
      SessionFailureKind.unavailable,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Annulla'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Non è stato possibile annullare lo spostamento.'),
      findsOneWidget,
    );
    expect(textOf(tester, 'session-date'), 'giovedì 3 dicembre 2026');

    app.sessions.moveFailure = null;
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Riprova'),
      ),
    );
    await tester.pumpAndSettle();
    expect(textOf(tester, 'session-date'), 'mercoledì 2 dicembre 2026');
  });

  testWidgets(
    'una semana con otra sesión de la reserva: no deja moverla y ofrece «Passa alla fine della prenotazione»',
    (tester) async {
      final app = await openSheet(tester, date: CalendarDate(2026, 12, 10));

      expect(
        textOf(tester, 'move-date-status'),
        'Quella settimana ha già una sessione di questa prenotazione.',
      );
      expect(
        find.text(
          "Una sessione per settimana: diventerebbe mer 23 dic, la settimana dopo l'ultima.",
        ),
        findsOneWidget,
      );
      expect(
        textOf(tester, 'move-blocker'),
        'Quella settimana ha già una sessione di questa prenotazione.',
      );
      expect(confirmOf(tester), isNull);

      await tester.tap(byKey('move-to-end'));
      await tester.pumpAndSettle();

      expect(find.text('mercoledì 23 dicembre 2026'), findsOneWidget);
      expect(app.sessions.checks.last.date, CalendarDate(2026, 12, 23));
      expect(textOf(tester, 'move-date-status'), 'Libero');
      expect(byKey('move-to-end'), findsNothing);
      expect(confirmOf(tester), isNotNull);
    },
  );

  testWidgets('un choque no deja moverla y dice por qué; un aviso, sí', (
    tester,
  ) async {
    final sessions = FakeSessionsRepository(buildBooking());
    sessions.statuses[thursday] = BookingDayStatus.busy;
    sessions.statuses[thursday.addDays(1)] = BookingDayStatus.blocked;
    await openSheet(tester, date: thursday, sessions: sessions);

    expect(
      textOf(tester, 'move-date-status'),
      "Si sovrappone a un'altra sessione",
    );
    expect(
      textOf(tester, 'move-blocker'),
      "Si sovrappone a un'altra sessione: scegli un'altra data o un'altra ora.",
    );
    expect(confirmOf(tester), isNull);

    await tester.tap(byKey('move-date'));
    await tester.pumpAndSettle();
    final picker = find.byType(DatePickerDialog);
    await tester.tap(
      find.descendant(of: picker, matching: find.text('4')).first,
    );
    await tester.pumpAndSettle();
    final ok = MaterialLocalizations.of(tester.element(picker)).okButtonLabel;
    await tester.tap(find.descendant(of: picker, matching: find.text(ok)));
    await tester.pumpAndSettle();

    expect(textOf(tester, 'move-date-status'), 'Giorno bloccato');
    expect(confirmOf(tester), isNotNull);
  });

  testWidgets(
    'si al mover choca (cambió mientras tanto), lo dice y no mueve nada',
    (tester) async {
      final app = await openSheet(tester, date: thursday);
      app.sessions.statuses[thursday] = BookingDayStatus.busy;

      await tester.tap(byKey('move-confirm'));
      await tester.pumpAndSettle();

      expect(
        textOf(tester, 'move-failure'),
        "gio 3 dic si sovrappone a un'altra sessione: non è stato spostato niente.",
      );
      expect(find.byType(MoveSessionScreen), findsOneWidget);
      expect(
        textOf(tester, 'move-date-status'),
        "Si sovrappone a un'altra sessione",
      );
      expect(
        app.sessions.sessions[sessionId(2)]!.date,
        CalendarDate(2026, 12, 2),
      );
    },
  );

  testWidgets(
    'sin fecha nueva hay que elegir otra fecha u hora; otra hora, el mismo día, también es mover',
    (tester) async {
      final app = await openSheet(tester);
      expect(
        textOf(tester, 'move-blocker'),
        "Scegli un'altra data o un'altra ora.",
      );
      expect(confirmOf(tester), isNull);
      expect(app.sessions.checks, isEmpty);

      await tester.tap(byKey('move-start-11:00'));
      await tester.pumpAndSettle();
      expect(app.sessions.checks.single.start, const ClockTime.hm(11, 0));
      expect(textOf(tester, 'move-summary'), 'mer 2 dic, arrivo alle 11:00');
      expect(confirmOf(tester), isNotNull);
    },
  );

  testWidgets('una sesión cocinada no se mueve: la hoja lo dice', (
    tester,
  ) async {
    await openSheet(
      tester,
      date: thursday,
      sessions: FakeSessionsRepository(
        buildBooking(statuses: {2: SessionStatus.cooked}),
      ),
    );
    expect(
      textOf(tester, 'move-failure'),
      'Questa sessione è «Cucinata»: non si può più spostare.',
    );
    expect(confirmOf(tester), isNull);
    expect(tester.widget<ListTile>(byKey('move-date')).enabled, isFalse);
  });

  testWidgets(
    'la última semana: la fila y la barra dicen que esa semana está ocupada, sin «Passa alla fine»',
    (tester) async {
      final app = await open(tester, '/sessioni/${sessionId(4)}');
      app.go('/sessioni/${sessionId(4)}/sposta?data=2026-12-10');
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'move-blocker'),
        'Quella settimana ha già una sessione di questa prenotazione.',
      );
      expect(byKey('move-to-end'), findsNothing);
      expect(confirmOf(tester), isNull);
    },
  );

  testWidgets('la X cierra sin mover; mientras mueve no se cierra', (
    tester,
  ) async {
    final app = await openSheet(tester, date: thursday);
    app.sessions.pendingMove = Completer<void>();
    await tester.tap(byKey('move-confirm'));
    await tester.pump();

    expect(find.text('Spostamento…'), findsOneWidget);
    expect(tester.widget<IconButton>(byKey('move-close')).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(MoveSessionScreen), findsOneWidget);

    app.sessions.pendingMove!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CookingSessionScreen), findsOneWidget);

    // Otra vez, y ahora la X.
    app.go('/sessioni/${sessionId(2)}/sposta?data=2026-12-04');
    await tester.pumpAndSettle();
    await tester.tap(byKey('move-close'));
    await tester.pumpAndSettle();
    expect(find.byType(CookingSessionScreen), findsOneWidget);
    expect(app.sessions.moves, hasLength(1));
  });

  testWidgets('una sesión que no existe lo dice', (tester) async {
    await open(tester, '/sessioni/nope/sposta?data=2026-12-03');
    expect(byKey('move-session-not-found'), findsOneWidget);
  });

  group('teléfono', () {
    testWidgets('a 375×667, «Sposta a …» queda en el tercio inferior', (
      tester,
    ) async {
      await openSheet(tester, date: thursday, size: const Size(375, 667));
      final rect = tester.getRect(byKey('move-confirm'));
      expect(rect.center.dy, greaterThan(667 * 2 / 3));
      expect(rect.height, greaterThanOrEqualTo(48));
    });

    testWidgets(
      'a 375×667, el calendario y el reloj en modo escritura tienen letra de 16 px o más',
      (tester) async {
        await openSheet(tester, date: thursday, size: const Size(375, 667));

        await tester.tap(byKey('move-date'));
        await tester.pumpAndSettle();
        final datePicker = find.byType(DatePickerDialog);
        final dateMaterial = MaterialLocalizations.of(
          tester.element(datePicker),
        );
        await tester.tap(find.byTooltip(dateMaterial.inputDateModeButtonLabel));
        await tester.pumpAndSettle();
        expectReadableInputs(tester);
        await tester.tap(
          find.descendant(
            of: datePicker,
            matching: find.text(dateMaterial.cancelButtonLabel),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(byKey('move-start-other'));
        await tester.pumpAndSettle();
        final timePicker = find.byType(TimePickerDialog);
        final timeMaterial = MaterialLocalizations.of(
          tester.element(timePicker),
        );
        await tester.tap(find.byTooltip(timeMaterial.inputTimeModeButtonLabel));
        await tester.pumpAndSettle();
        expectReadableInputs(tester);
        await tester.tap(
          find.descendant(
            of: timePicker,
            matching: find.text(timeMaterial.cancelButtonLabel),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(MoveSessionScreen), findsOneWidget);
      },
    );

    for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
      testWidgets(
        'a 375×667 sin desbordes, con la semana ocupada (${locale.languageCode})',
        (tester) async {
          await openSheet(
            tester,
            date: CalendarDate(2026, 12, 10),
            size: const Size(375, 667),
            locale: locale,
          );
          expect(byKey('move-to-end'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.drag(byKey('move-form'), const Offset(0, -1000));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}

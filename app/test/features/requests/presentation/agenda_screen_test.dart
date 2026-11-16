// Agenda: vista mensual y semanal con franjas, lista "senza data", días
// bloqueados (con «Annulla»), feriados y el botón «Blocca giorni».
// "Hoy" en los tests: lunes 19/10/2026 (testNow).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/presentation/block_range_dialog.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/text_input_guard.dart';

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

  testWidgets('los días de los meses vecinos van en el color secundario, sin transparencia (contraste AA)', (
    tester,
  ) async {
    await openAgenda(tester);

    // 28/09 aparece en la grilla de octubre.
    final number = tester.widget<Text>(
      find.descendant(of: day('2026-09-28'), matching: find.text('28')),
    );
    final colors = Theme.of(tester.element(day('2026-09-28'))).colorScheme;
    expect(number.style?.color, colors.onSurfaceVariant);
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

  testWidgets('a la medianoche de Roma "hoy" pasa al día siguiente sin reabrir', (
    tester,
  ) async {
    // 23:59:30 del lunes 19/10 en Roma.
    var now = DateTime.utc(2026, 10, 19, 21, 59, 30);
    await pumpChefApp(
      tester,
      requests: sample(),
      location: '/agenda',
      size: const Size(400, 2000),
      clock: () => now,
    );
    FontWeight? weightOfDay(String iso, String number) => tester
        .widget<Text>(
          find.descendant(of: day(iso), matching: find.text(number)),
        )
        .style
        ?.fontWeight;

    expect(find.text('lunedì 19 ottobre 2026'), findsOneWidget);
    expect(weightOfDay('2026-10-19', '19'), FontWeight.w700);

    now = now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();

    expect(find.text('martedì 20 ottobre 2026'), findsOneWidget);
    expect(weightOfDay('2026-10-20', '20'), FontWeight.w700);
    expect(weightOfDay('2026-10-19', '19'), isNot(FontWeight.w700));
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
        // Un día bloqueado con nota, para ver también esa tarjeta.
        availability: FakeAvailabilityRepository(
          blocked: [
            BlockedDay(id: 'b1', date: CalendarDate(2026, 10, 19), note: 'Ferie'),
          ],
        ),
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

  group('días bloqueados y feriados', () {
    final wednesdayIso = wednesday.toIso();
    final friday = CalendarDate(2026, 10, 23);

    Future<ChefApp> openDays(
      WidgetTester tester, {
      FakeAvailabilityRepository? availability,
      Size size = const Size(400, 900),
    }) async {
      final app = await pumpChefApp(
        tester,
        requests: sample(),
        availability: availability,
        location: '/agenda',
        size: size,
      );
      expect(find.byType(AgendaScreen), findsOneWidget);
      return app;
    }

    Future<void> selectDay(WidgetTester tester, String iso) async {
      await tester.tap(day(iso));
      await tester.pumpAndSettle();
    }

    Finder byKey(String key) => find.byKey(ValueKey(key));

    TextDecoration? decorationOf(WidgetTester tester, String iso) => tester
        .widget<Text>(
          find.descendant(
            of: day(iso),
            matching: find.text('${CalendarDate.parse(iso).day}'),
          ),
        )
        .style
        ?.decoration;

    Finder snackBarAction(String label) => find.descendant(
      of: find.byType(SnackBar),
      matching: find.text(label),
    );

    testWidgets('el miércoles 21/10 dice el horario y cuántas solicitudes lo preferían', (
      tester,
    ) async {
      await openDays(tester);
      await selectDay(tester, wednesdayIso);

      expect(find.text("Orario 09:00–15:00: il sito lo offre se c'è posto."), findsOneWidget);
      expect(
        find.text('2 richieste preferivano questo giorno: bloccarlo non le rifiuta.'),
        findsOneWidget,
        reason: 'el sample tiene dos activas y una rechazada',
      );
      expect(byKey('availability-block-$wednesdayIso'), findsOneWidget);
    });

    testWidgets('«Blocca questo giorno» bloquea: celda tachada y aviso con «Annulla», que lo desbloquea', (
      tester,
    ) async {
      final app = await openDays(tester);
      await selectDay(tester, wednesdayIso);
      expect(decorationOf(tester, wednesdayIso), isNot(TextDecoration.lineThrough));

      await tester.tap(byKey('availability-block-$wednesdayIso'));
      await tester.pumpAndSettle();

      expect(app.availability.blockCalls.single, [(date: wednesday, note: null)]);
      expect(decorationOf(tester, wednesdayIso), TextDecoration.lineThrough);
      expect(find.text('Giorno bloccato: il sito non lo offre.'), findsOneWidget);
      expect(byKey('availability-unblock-$wednesdayIso'), findsOneWidget);
      expect(find.text('Giorno bloccato.'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(RegExp(r'21 ottobre 2026, 2 richieste, bloccato$')),
        findsOneWidget,
      );
      semantics.dispose();

      await tester.tap(snackBarAction('Annulla'));
      await tester.pumpAndSettle();

      expect(app.availability.unblockCalls.single, ['block-1']);
      expect(app.availability.blocked, isEmpty);
      expect(decorationOf(tester, wednesdayIso), isNot(TextDecoration.lineThrough));
      expect(byKey('availability-block-$wednesdayIso'), findsOneWidget);
    });

    testWidgets('desbloquear también se deshace, y vuelve con su nota', (tester) async {
      final availability = FakeAvailabilityRepository(
        blocked: [BlockedDay(id: 'b1', date: friday, note: 'Ferie')],
      );
      await openDays(tester, availability: availability);
      await selectDay(tester, friday.toIso());
      expect(find.text('Ferie'), findsOneWidget);

      await tester.tap(byKey('availability-unblock-${friday.toIso()}'));
      await tester.pumpAndSettle();
      expect(availability.blocked, isEmpty);
      expect(find.text('Giorno sbloccato.'), findsOneWidget);
      expect(find.text('Ferie'), findsNothing);

      await tester.tap(snackBarAction('Annulla'));
      await tester.pumpAndSettle();
      expect(availability.blocked[friday]?.note, 'Ferie');
      expect(find.text('Ferie'), findsOneWidget);
    });

    testWidgets('el sábado no tiene botón y el 16/10 dice «Giorno passato.»', (tester) async {
      await openDays(tester);

      await selectDay(tester, '2026-10-24');
      expect(find.text('Non lavori in questo giorno della settimana.'), findsOneWidget);
      expect(byKey('availability-block-2026-10-24'), findsNothing);

      await selectDay(tester, '2026-10-16');
      expect(find.text('Giorno passato.'), findsOneWidget);
      expect(byKey('availability-block-2026-10-16'), findsNothing);
      expect(byKey('availability-unblock-2026-10-16'), findsNothing);
    });

    testWidgets('dos meses adelante, el 8/12 dice «Festività: Immacolata Concezione» y lleva el punto', (
      tester,
    ) async {
      await openDays(tester);
      for (var i = 0; i < 2; i++) {
        await tester.tap(byKey('agenda-next'));
        await tester.pumpAndSettle();
      }
      await selectDay(tester, '2026-12-08');

      expect(find.text('Festività: Immacolata Concezione'), findsOneWidget);
      expect(byKey('agenda-day-holiday-2026-12-08'), findsOneWidget);
      expect(byKey('agenda-day-holiday-2026-12-25'), findsOneWidget);
      // Santo Stefano cae sábado, que no trabaja: sin punto.
      expect(byKey('agenda-day-holiday-2026-12-26'), findsNothing);
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          RegExp(r'8 dicembre 2026, nessuna richiesta, Festività: Immacolata Concezione$'),
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('si el servidor falla: aviso con «Riprova» y la celda no queda tachada', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository()..failBlock = true;
      await openDays(tester, availability: availability);
      await selectDay(tester, wednesdayIso);

      await tester.tap(byKey('availability-block-$wednesdayIso'));
      await tester.pumpAndSettle();

      expect(
        find.text('Non è stato possibile salvare. Controlla la connessione e riprova.'),
        findsOneWidget,
      );
      expect(decorationOf(tester, wednesdayIso), isNot(TextDecoration.lineThrough));
      expect(byKey('availability-block-$wednesdayIso'), findsOneWidget);

      availability.failBlock = false;
      await tester.tap(snackBarAction('Riprova'));
      await tester.pumpAndSettle();
      expect(decorationOf(tester, wednesdayIso), TextDecoration.lineThrough);
      expect(availability.blocked.keys, [wednesday]);
    });

    testWidgets('si no se pudo cargar: la tarjeta lo dice y ofrece «Riprova»; el botón flotante espera', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository()..failFetch = true;
      await openDays(tester, availability: availability);

      expect(find.text('Impossibile caricare i giorni bloccati.'), findsOneWidget);
      expect(
        tester.widget<FloatingActionButton>(byKey('agenda-block-range')).onPressed,
        isNull,
      );

      availability.failFetch = false;
      await tester.tap(byKey('availability-retry'));
      await tester.pumpAndSettle();
      expect(byKey('availability-block-2026-10-19'), findsOneWidget, reason: 'hoy se puede bloquear');
      expect(
        tester.widget<FloatingActionButton>(byKey('agenda-block-range')).onPressed,
        isNotNull,
      );
    });

    testWidgets('agregar una nota a un día bloqueado (campo de 16 px o más)', (tester) async {
      final availability = FakeAvailabilityRepository(
        blocked: [BlockedDay(id: 'b1', date: friday)],
      );
      await openDays(tester, availability: availability);
      await selectDay(tester, friday.toIso());

      await tester.tap(byKey('availability-note-${friday.toIso()}'));
      await tester.pumpAndSettle();
      expect(byKey('availability-note-dialog'), findsOneWidget);
      expect(find.text('Nota (la vedi solo tu)'), findsOneWidget);
      expectReadableInputs(tester);

      await tester.enterText(byKey('availability-note-field'), 'Ferie');
      await tester.tap(byKey('availability-note-save'));
      await tester.pumpAndSettle();

      expect(availability.noteCalls.single, (id: 'b1', note: 'Ferie'));
      expect(find.text('Ferie'), findsOneWidget);
      expect(find.text('Modifica nota'), findsOneWidget);
    });

    testWidgets('el botón flotante abre el calendario de rango y bloquea solo los días que faltan', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository(
        blocked: [BlockedDay(id: 'b1', date: friday, note: 'Dentista')],
      );
      // 600 px: el encabezado del calendario de Flutter no achica la fecha de
      // inicio y, con la letra de los tests (cada letra es un cuadrado del
      // tamaño de la fuente), «Data di inizio – » no entra en 400 px. Con la
      // letra real entra (capturas a 375 px del PR).
      await openDays(tester, availability: availability, size: const Size(600, 900));

      await tester.tap(byKey('agenda-block-range'));
      await tester.pumpAndSettle();
      final picker = find.byType(DateRangePickerDialog);
      expect(picker, findsOneWidget);
      expect(
        find.descendant(of: picker, matching: find.text("Tocca il primo e l'ultimo giorno")),
        findsOneWidget,
      );

      Finder pickerDay(String number) =>
          find.descendant(of: picker, matching: find.text(number)).first;
      await tester.tap(pickerDay('21'));
      await tester.pumpAndSettle();
      await tester.tap(pickerDay('25'));
      await tester.pumpAndSettle();
      final save = MaterialLocalizations.of(tester.element(picker)).saveButtonLabel;
      await tester.tap(find.descendant(of: picker, matching: find.text(save)));
      await tester.pumpAndSettle();

      expect(find.byType(BlockRangeDialog), findsOneWidget);
      expect(find.text('5 giorni · 3 in cui lavori · 1 già bloccato'), findsOneWidget);
      expectReadableInputs(tester);
      await tester.enterText(byKey('block-range-note'), 'Ferie');
      await tester.tap(byKey('block-range-confirm'));
      await tester.pumpAndSettle();

      expect(availability.blockCalls.single, [
        (date: CalendarDate(2026, 10, 21), note: 'Ferie'),
        (date: CalendarDate(2026, 10, 22), note: 'Ferie'),
        (date: CalendarDate(2026, 10, 24), note: 'Ferie'),
        (date: CalendarDate(2026, 10, 25), note: 'Ferie'),
      ]);
      expect(availability.blocked[friday]?.note, 'Dentista');
      expect(find.text('4 giorni bloccati.'), findsOneWidget);
      expect(decorationOf(tester, '2026-10-22'), TextDecoration.lineThrough);
    });

    testWidgets('vista semanal: el bloqueado dice que la web no lo ofrece, con su nota y «Sblocca»', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository(
        blocked: [BlockedDay(id: 'b1', date: friday, note: 'Ferie')],
      );
      await openDays(tester, availability: availability, size: const Size(400, 2400));
      await tester.tap(byKey('agenda-view-week'));
      await tester.pumpAndSettle();

      final fridayCard = byKey('agenda-week-day-${friday.toIso()}');
      for (final finder in [
        find.text('Giorno bloccato: il sito non lo offre.'),
        find.text('Ferie'),
        byKey('availability-unblock-${friday.toIso()}'),
      ]) {
        expect(find.descendant(of: fridayCard, matching: finder), findsOneWidget);
      }
      expect(byKey('availability-block-2026-10-19'), findsOneWidget, reason: 'hoy se puede bloquear');
      expect(byKey('availability-block-$wednesdayIso'), findsOneWidget);
      expect(byKey('availability-block-2026-10-24'), findsNothing, reason: 'el sábado no trabaja');

      await tester.tap(byKey('availability-block-$wednesdayIso'));
      await tester.pumpAndSettle();
      expect(availability.blocked.keys, containsAll([friday, wednesday]));
      expect(byKey('availability-unblock-$wednesdayIso'), findsOneWidget);
    });

    testWidgets('deslizar para actualizar vuelve a leer la bandeja y los días bloqueados', (
      tester,
    ) async {
      final app = await openDays(tester);
      final availabilityCalls = app.availability.fetchCalls;
      final requestCalls = app.requests.fetchCalls;

      await tester.fling(byKey('agenda'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(app.availability.fetchCalls, availabilityCalls + 1);
      expect(app.requests.fetchCalls, requestCalls + 1);
    });

    testWidgets('a 1024 px (riel lateral) se ve lo mismo', (tester) async {
      await openDays(tester, size: const Size(1024, 900));
      expect(byKey('chef-nav-rail'), findsOneWidget);

      await selectDay(tester, wednesdayIso);
      expect(find.text("Orario 09:00–15:00: il sito lo offre se c'è posto."), findsOneWidget);
      expect(byKey('availability-block-$wednesdayIso'), findsOneWidget);
      expect(byKey('agenda-block-range'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a 375×667 «Blocca giorni» queda en el tercio inferior y el aviso no lo tapa', (
      tester,
    ) async {
      await openDays(tester, size: const Size(375, 667));
      final fab = byKey('agenda-block-range');
      expect(tester.getCenter(fab).dy, greaterThan(667 * 2 / 3));

      final block = byKey('availability-block-2026-10-19');
      await tester.ensureVisible(block);
      await tester.pumpAndSettle();
      await tester.tap(block);
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        tester.getRect(fab).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(SnackBar)).top),
      );
    });
  });
}

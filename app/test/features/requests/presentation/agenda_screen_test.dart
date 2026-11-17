// Agenda: vista mensual y semanal con franjas, lista "senza data", días
// bloqueados (con «Annulla»), feriados y el botón «Blocca giorni».
// "Hoy" en los tests: lunes 19/10/2026 (testNow).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart';
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
    // Hoy (19/10) está elegido y no tiene pedidos (ni sesiones).
    expect(find.text('Niente per questo giorno: né sessioni né richieste.'), findsOneWidget);
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

  testWidgets('en el iPhone, tocar la barra de estado sube la lista', (
    tester,
  ) async {
    // Una barra de estado de 47 de alto: el Scaffold atiende el toque si su
    // zona de arriba está ahí.
    tester.view.padding = const FakeViewPadding(top: 47);
    tester.view.viewPadding = const FakeViewPadding(top: 47);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([
        for (var i = 0; i < 20; i++)
          buildRequest(id: 'senza-data-$i', noDate: true),
      ]),
      location: '/agenda',
      size: const Size(375, 667),
    );
    final list = find.byKey(const ValueKey('agenda'));
    await tester.drag(list, const Offset(0, -800));
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    expect(position.pixels, greaterThan(0));

    // Lo que manda iOS al tocar la barra de estado.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/status_bar',
      const JSONMethodCodec().encodeMethodCall(
        const MethodCall('handleScrollToTop'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('desde la agenda, confirmar una reserva tapa la barra; al volver regresa a la agenda, con la '
      'barra y Agenda elegida', (tester) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([
        buildRequest(
          id: 'no-date',
          name: 'Sara Gialli',
          noDate: true,
          weeks: 4,
          estimate: fourWeeksEstimate,
        ),
      ]),
      location: '/agenda',
      size: const Size(400, 2000),
    );
    final navBar = find.byKey(const ValueKey('chef-nav-bar'));
    expect(tester.widget<NavigationBar>(navBar).selectedIndex, 2);
    await tester.tap(tile('no-date'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action-confirm-booking')));
    await tester.pumpAndSettle();
    expect(navBar, findsNothing, reason: 'la hoja tapa la barra');
    await tester.tap(find.byKey(const ValueKey('booking-confirm')));
    await tester.pumpAndSettle();
    expect(app.bookings.confirmations, hasLength(1));
    expect(navBar, findsNothing, reason: 'la pantalla final tapa la barra');

    await tester.tap(find.byKey(const ValueKey('booking-done-close')));
    await tester.pumpAndSettle();
    expect(find.byType(RequestDetailScreen), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(AgendaScreen), findsOneWidget);
    expect(navBar.hitTestable(), findsOneWidget);
    expect(tester.widget<NavigationBar>(navBar).selectedIndex, 2);
    expect(
      find.descendant(of: navBar, matching: find.byType(NavigationDestination)),
      findsNWidgets(4),
    );
  });

  group('la bandeja desde el arranque (armada antes de que cargue la cuenta, con la lista vacía)', () {
    Finder byKey(String key) => find.byKey(ValueKey(key));

    testWidgets('si no se pudo leer, el error con «Riprova», que la vuelve a leer', (
      tester,
    ) async {
      final requests = sample()..failFetch = true;
      await pumpChefApp(
        tester,
        requests: requests,
        location: '/agenda',
        size: const Size(400, 2000),
      );
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(byKey('load-error'), findsOneWidget);

      requests.failFetch = false;
      await tester.tap(byKey('load-error-retry'));
      await tester.pumpAndSettle();
      expect(byKey('load-error'), findsNothing);
      expect(tile('no-date'), findsOneWidget);
    });

    testWidgets('mientras se lee, la barra de carga; al llegar, los pedidos', (
      tester,
    ) async {
      final requests = sample()..pendingFetch = Completer<void>();
      await pumpChefApp(
        tester,
        requests: requests,
        location: '/agenda',
        size: const Size(400, 2000),
        settle: false,
      );
      for (var i = 0; i < 10 && find.byType(AgendaScreen).evaluate().isEmpty; i++) {
        await tester.pump();
      }
      await tester.pump();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(byKey('agenda-loading'), findsOneWidget);

      requests.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(byKey('agenda-loading'), findsNothing);
      expect(tile('no-date'), findsOneWidget);
    });
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

    const saveFailed = 'Non è stato possibile salvare. Controlla la connessione e riprova.';

    Future<ChefApp> openDays(
      WidgetTester tester, {
      FakeAvailabilityRepository? availability,
      FakeChefRequestsRepository? requests,
      Size size = const Size(400, 900),
      DateTime Function()? clock,
    }) async {
      final app = await pumpChefApp(
        tester,
        requests: requests ?? sample(),
        availability: availability,
        location: '/agenda',
        size: size,
        clock: clock,
      );
      expect(find.byType(AgendaScreen), findsOneWidget);
      return app;
    }

    Future<void> selectDay(WidgetTester tester, String iso) async {
      await tester.tap(day(iso));
      await tester.pumpAndSettle();
    }

    Finder byKey(String key) => find.byKey(ValueKey(key));

    VoidCallback? onPressedOf(WidgetTester tester, String key) =>
        tester.widget<ButtonStyleButton>(byKey(key)).onPressed;

    Finder snackBarClose() => find.descendant(
      of: find.byType(SnackBar),
      matching: find.byIcon(Icons.close),
    );

    /// Abre el calendario del botón flotante, elige de [from] a [to] (días del
    /// mes que muestra) y toca «Salva».
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
      final save = MaterialLocalizations.of(tester.element(picker)).saveButtonLabel;
      await tester.tap(find.descendant(of: picker, matching: find.text(save)));
      await tester.pumpAndSettle();
    }

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
      // El punto va debajo del número, no encima de las cifras.
      for (final (iso, number) in [('2026-12-08', '8'), ('2026-12-25', '25')]) {
        expect(
          tester.getRect(byKey('agenda-day-holiday-$iso')).top,
          greaterThanOrEqualTo(
            tester.getRect(find.descendant(of: day(iso), matching: find.text(number))).bottom - 1,
          ),
          reason: iso,
        );
      }
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

      expect(find.text(saveFailed), findsOneWidget);
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

    testWidgets('agregar una nota a un día bloqueado: arriba, con foco, 200 letras y campo de 16 px o más', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository(
        blocked: [BlockedDay(id: 'b1', date: friday)],
      );
      await openDays(tester, availability: availability);
      await selectDay(tester, friday.toIso());

      await tester.tap(byKey('availability-note-${friday.toIso()}'));
      await tester.pumpAndSettle();
      expect(byKey('availability-note-dialog'), findsOneWidget);
      expect(find.text('Nota (la vedi solo tu)'), findsOneWidget);
      // La instrucción de privacidad se ve siempre, aparte del ejemplo.
      expect(find.text('Non scrivere dati sulla salute.'), findsOneWidget);
      expectReadableInputs(tester);
      // Arriba de la pantalla (el teclado de iOS no tapa «Salva») y con el
      // teclado ya abierto.
      expect(
        tester.widget<AlertDialog>(byKey('availability-note-dialog')).alignment,
        Alignment.topCenter,
      );
      final editable = find.descendant(
        of: byKey('availability-note-field'),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
      expect(
        tester.widget<TextField>(byKey('availability-note-field')).textCapitalization,
        TextCapitalization.sentences,
      );
      await tester.enterText(byKey('availability-note-field'), 'x' * 250);
      expect(tester.widget<EditableText>(editable).controller.text, hasLength(maxNoteLength));

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
      // De hoy a un año (366 días contando los dos), solo el calendario: un
      // rango más largo no se podría resumir.
      final dialog = tester.widget<DateRangePickerDialog>(picker);
      expect(CalendarDate.fromDateTime(dialog.firstDate), CalendarDate(2026, 10, 19));
      expect(CalendarDate.fromDateTime(dialog.lastDate), CalendarDate(2027, 10, 19));
      expect(dialog.initialEntryMode, DatePickerEntryMode.calendarOnly);

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
      // Hay un botón igual en cada día: VoiceOver dice también la fecha.
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('Blocca questo giorno, mercoledì 21 ottobre 2026'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Sblocca, venerdì 23 ottobre 2026'), findsOneWidget);
      semantics.dispose();

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
      expect(find.byType(SnackBar), findsNothing);
    });

    const refreshFailed = 'Aggiornamento non riuscito. Controlla la connessione.';

    testWidgets('«Ricarica», arriba, hace lo mismo sin deslizar (VoiceOver y el mouse no deslizan); si falla, avisa', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final app = await openDays(tester);
      final reload = byKey('chef-reload');
      expect(
        tester.getSemantics(reload),
        isSemantics(tooltip: 'Ricarica', isButton: true, hasTapAction: true),
      );
      final calls = (
        availability: app.availability.fetchCalls,
        requests: app.requests.fetchCalls,
        sessions: app.sessions.fetchCalls,
      );

      await tester.tap(reload);
      await tester.pumpAndSettle();
      expect(app.availability.fetchCalls, calls.availability + 1);
      expect(app.requests.fetchCalls, calls.requests + 1);
      expect(app.sessions.fetchCalls, calls.sessions + 1);
      expect(find.byType(SnackBar), findsNothing);

      app.requests.failFetch = true;
      await tester.tap(reload);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(SnackBar), matching: find.text(refreshFailed)),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('si al deslizar no se pueden leer los días bloqueados, avisa y deja lo que había', (
      tester,
    ) async {
      final today = CalendarDate(2026, 10, 19);
      final availability = FakeAvailabilityRepository(
        blocked: [BlockedDay(id: 'b1', date: today, note: 'Ferie')],
      );
      await openDays(tester, availability: availability);

      availability.failFetch = true;
      await tester.fling(byKey('agenda'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: find.byType(SnackBar), matching: find.text(refreshFailed)),
        findsOneWidget,
      );
      expect(decorationOf(tester, today.toIso()), TextDecoration.lineThrough);
      expect(find.text('Ferie'), findsOneWidget);
      expect(byKey('availability-unblock-${today.toIso()}'), findsOneWidget);
    });

    testWidgets('si al deslizar no se puede leer la bandeja, avisa y deja los pedidos', (
      tester,
    ) async {
      final app = await openDays(tester);

      app.requests.failFetch = true;
      await tester.fling(byKey('agenda'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: find.byType(SnackBar), matching: find.text(refreshFailed)),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(byKey('agenda-day-count-2026-10-21')).data,
        '2',
      );
      expect(tile('no-date'), findsOneWidget);
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

    testWidgets('a 375×667, al final de la lista el botón flotante no tapa nada (96 px abajo)', (
      tester,
    ) async {
      await openDays(tester, size: const Size(375, 667));
      await tester.drag(byKey('agenda'), const Offset(0, -3000));
      await tester.pumpAndSettle();

      expect(
        tester.getRect(byKey('agenda-without-date')).bottom,
        lessThanOrEqualTo(tester.getRect(byKey('agenda-block-range')).top),
      );
    });

    testWidgets('a 375×667, tocar un día de la sexta semana trae su tarjeta a la vista, y el aviso no tapa sus botones', (
      tester,
    ) async {
      // Lunes 16/11/2026: noviembre ocupa seis semanas (de lunes a domingo).
      await openDays(
        tester,
        size: const Size(375, 667),
        clock: () => DateTime.utc(2026, 11, 16, 11),
      );
      await selectDay(tester, '2026-11-30');

      final block = byKey('availability-block-2026-11-30');
      expect(block.hitTestable(), findsOneWidget, reason: 'sin desplazar a mano');
      final fab = byKey('agenda-block-range');
      expect(tester.getRect(block).overlaps(tester.getRect(fab)), isFalse);
      await tester.tap(block);
      await tester.pumpAndSettle();

      final snackBar = tester.getRect(find.byType(SnackBar));
      for (final key in [
        'availability-status-2026-11-30',
        'availability-note-2026-11-30',
        'availability-unblock-2026-11-30',
      ]) {
        final rect = tester.getRect(byKey(key));
        expect(rect.overlaps(snackBar), isFalse, reason: '$key debajo del aviso');
        expect(rect.overlaps(tester.getRect(fab)), isFalse, reason: '$key debajo del botón flotante');
        expect(byKey(key).hitTestable(), findsOneWidget, reason: key);
      }
    });

    testWidgets('los avisos se van solos: el de «Annulla» a los 6 s y el de error a los 10 s', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository();
      await openDays(tester, availability: availability);
      await selectDay(tester, wednesdayIso);

      await tester.tap(byKey('availability-block-$wednesdayIso'));
      await tester.pumpAndSettle();
      await tester.pump(undoSnackBarDuration - const Duration(seconds: 1));
      expect(snackBarAction('Annulla'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      availability.failUnblock = true;
      await tester.tap(byKey('availability-unblock-$wednesdayIso'));
      await tester.pumpAndSettle();
      expect(find.text(saveFailed), findsOneWidget);
      await tester.pump(errorSnackBarDuration - const Duration(seconds: 1));
      expect(snackBarAction('Riprova'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('con VoiceOver los avisos no se van solos: se cierran con la X', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        accessibleNavigation: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final availability = FakeAvailabilityRepository();
      await openDays(tester, availability: availability);
      await selectDay(tester, wednesdayIso);

      await tester.tap(byKey('availability-block-$wednesdayIso'));
      await tester.pumpAndSettle();
      await tester.pump(undoSnackBarDuration + const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(snackBarAction('Annulla'), findsOneWidget);
      await tester.tap(snackBarClose());
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      availability.failUnblock = true;
      await tester.tap(byKey('availability-unblock-$wednesdayIso'));
      await tester.pumpAndSettle();
      await tester.pump(errorSnackBarDuration + const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(snackBarAction('Riprova'), findsOneWidget);
      await tester.tap(snackBarClose());
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('mientras guarda, los botones del día quedan deshabilitados y se ve un indicador', (
      tester,
    ) async {
      const today = '2026-10-19';
      final availability = FakeAvailabilityRepository()..pendingBlock = Completer<void>();
      await openDays(tester, availability: availability);
      Finder spinner() => find.descendant(
        of: byKey('availability-day-$today'),
        matching: find.byType(CircularProgressIndicator),
      );

      await tester.tap(byKey('availability-block-$today'));
      await tester.pump();
      // Ya se ve bloqueado, pero hasta que el servidor conteste no se puede
      // desbloquear ni poner la nota (un segundo toque cruzaría los pedidos).
      expect(onPressedOf(tester, 'availability-unblock-$today'), isNull);
      expect(onPressedOf(tester, 'availability-note-$today'), isNull);
      expect(spinner(), findsOneWidget);

      availability.pendingBlock!.complete();
      await tester.pumpAndSettle();
      expect(onPressedOf(tester, 'availability-unblock-$today'), isNotNull);
      expect(onPressedOf(tester, 'availability-note-$today'), isNotNull);
      expect(spinner(), findsNothing);

      availability.pendingUnblock = Completer<void>();
      await tester.tap(byKey('availability-unblock-$today'));
      await tester.pump();
      expect(onPressedOf(tester, 'availability-block-$today'), isNull);
      expect(spinner(), findsOneWidget);

      availability.pendingUnblock!.complete();
      await tester.pumpAndSettle();
      expect(onPressedOf(tester, 'availability-block-$today'), isNotNull);
      expect(spinner(), findsNothing);
    });

    testWidgets('si falla «Annulla» de un bloqueo, avisa con «Riprova», que lo desbloquea', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository();
      await openDays(tester, availability: availability);
      await selectDay(tester, wednesdayIso);
      await tester.tap(byKey('availability-block-$wednesdayIso'));
      await tester.pumpAndSettle();

      availability.failUnblock = true;
      await tester.tap(snackBarAction('Annulla'));
      await tester.pumpAndSettle();
      expect(find.text(saveFailed), findsOneWidget);
      expect(decorationOf(tester, wednesdayIso), TextDecoration.lineThrough);

      availability.failUnblock = false;
      await tester.tap(snackBarAction('Riprova'));
      await tester.pumpAndSettle();
      expect(availability.blocked, isEmpty);
      expect(decorationOf(tester, wednesdayIso), isNot(TextDecoration.lineThrough));
    });

    testWidgets('si falla «Annulla» de un desbloqueo, avisa con «Riprova», que lo vuelve a bloquear con su nota', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository(
        blocked: [BlockedDay(id: 'b1', date: friday, note: 'Ferie')],
      );
      await openDays(tester, availability: availability);
      await selectDay(tester, friday.toIso());
      await tester.tap(byKey('availability-unblock-${friday.toIso()}'));
      await tester.pumpAndSettle();

      availability.failBlock = true;
      await tester.tap(snackBarAction('Annulla'));
      await tester.pumpAndSettle();
      expect(find.text(saveFailed), findsOneWidget);
      expect(decorationOf(tester, friday.toIso()), isNot(TextDecoration.lineThrough));

      availability.failBlock = false;
      await tester.tap(snackBarAction('Riprova'));
      await tester.pumpAndSettle();
      expect(availability.blocked[friday]?.note, 'Ferie');
      expect(decorationOf(tester, friday.toIso()), TextDecoration.lineThrough);
      expect(find.text('Ferie'), findsOneWidget);
    });

    testWidgets('si falla «Sblocca» o la nota, el día vuelve a como estaba y «Riprova» lo vuelve a intentar', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository(
        blocked: [BlockedDay(id: 'b1', date: friday, note: 'Ferie')],
      )..failNote = true;
      await openDays(tester, availability: availability);
      await selectDay(tester, friday.toIso());

      await tester.tap(byKey('availability-note-${friday.toIso()}'));
      await tester.pumpAndSettle();
      await tester.enterText(byKey('availability-note-field'), 'Vacanze');
      await tester.tap(byKey('availability-note-save'));
      await tester.pumpAndSettle();
      expect(find.text(saveFailed), findsOneWidget);
      expect(find.text('Ferie'), findsOneWidget);

      availability.failNote = false;
      await tester.tap(snackBarAction('Riprova'));
      await tester.pumpAndSettle();
      expect(availability.blocked[friday]?.note, 'Vacanze');
      expect(find.text('Vacanze'), findsOneWidget);

      availability.failUnblock = true;
      await tester.tap(byKey('availability-unblock-${friday.toIso()}'));
      await tester.pumpAndSettle();
      expect(find.text(saveFailed), findsOneWidget);
      expect(decorationOf(tester, friday.toIso()), TextDecoration.lineThrough);

      availability.failUnblock = false;
      await tester.tap(snackBarAction('Riprova'));
      await tester.pumpAndSettle();
      expect(availability.blocked, isEmpty);
      expect(find.text('Giorno sbloccato.'), findsOneWidget);
    });

    testWidgets('«Sblocca N giorni» del rango desbloquea los que estaban bloqueados', (
      tester,
    ) async {
      final availability = FakeAvailabilityRepository(
        blocked: [BlockedDay(id: 'b1', date: friday, note: 'Dentista')],
      );
      // 600 px: ver el test del rango de arriba.
      await openDays(tester, availability: availability, size: const Size(600, 900));
      await pickRange(tester, '21', '25');
      expect(find.text('Sblocca 1 giorno'), findsOneWidget);

      await tester.tap(byKey('block-range-unblock'));
      await tester.pumpAndSettle();
      expect(availability.unblockCalls.single, ['b1']);
      expect(availability.blockCalls, isEmpty);
      expect(availability.blocked, isEmpty);
      expect(find.text('Giorno sbloccato.'), findsOneWidget);
      expect(decorationOf(tester, friday.toIso()), isNot(TextDecoration.lineThrough));
    });

    testWidgets('«N richieste…» solo en un día abierto o bloqueado, no en uno pasado ni sin horario', (
      tester,
    ) async {
      await openDays(
        tester,
        requests: FakeChefRequestsRepository([
          buildRequest(id: 'past', name: 'Giulia Rossi', preferredDate: CalendarDate(2026, 10, 16)),
          buildRequest(id: 'saturday', name: 'Marco Bianchi', preferredDate: CalendarDate(2026, 10, 24)),
        ]),
      );
      for (final (iso, id) in [('2026-10-16', 'past'), ('2026-10-24', 'saturday')]) {
        await selectDay(tester, iso);
        expect(tile(id), findsOneWidget);
        expect(find.textContaining('preferiva'), findsNothing, reason: iso);
      }
    });
  });
}

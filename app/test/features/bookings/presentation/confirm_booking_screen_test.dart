// Hoja «Conferma prenotazione» en la app, desde el detalle de un pedido nuevo:
// lo prellenado, lo que dice el servidor de cada semana, el campo del precio
// con letra de 16 px (si no, iOS hace zoom), la acción principal en el tercio
// inferior a 375×667, el envío con el botón deshabilitado y, al confirmar, el
// WhatsApp en el idioma de la clienta.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/text_input_guard.dart';

void main() {
  final monday = CalendarDate(2026, 11, 23);
  final mondays = weeklyDates(monday, 4);

  ChefRequest weekly({
    int weeks = 4,
    RequestEstimate? estimate = fourWeeksEstimate,
  }) => buildRequest(
    weeks: weeks,
    preferredDate: monday,
    estimate: estimate,
    seenAt: testNow,
  );

  Finder byKey(String key) => find.byKey(ValueKey(key));

  /// El detalle del pedido y, con [open], la hoja abierta desde su botón.
  Future<ChefApp> openSheet(
    WidgetTester tester, {
    ChefRequest? request,
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
    void Function(FakeBookingsRepository bookings)? configure,
    bool open = true,
  }) async {
    final requests = FakeChefRequestsRepository([request ?? weekly()]);
    final bookings = FakeBookingsRepository(requests: requests);
    configure?.call(bookings);
    final app = await pumpChefApp(
      tester,
      requests: requests,
      bookings: bookings,
      location: '/richieste/req-1',
      size: size,
      deviceLocales: [locale],
    );
    if (open) {
      await tester.tap(byKey('action-confirm-booking'));
      await tester.pumpAndSettle();
    }
    return app;
  }

  FilledButton confirmButton(WidgetTester tester) =>
      tester.widget<FilledButton>(byKey('booking-confirm'));

  String priceText(WidgetTester tester) =>
      tester.widget<TextField>(byKey('booking-price')).controller!.text;

  testWidgets(
    'desde el detalle, «Conferma prenotazione» abre la hoja prellenada',
    (tester) async {
      await openSheet(tester);

      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(
        find.widgetWithText(AppBar, 'Conferma prenotazione'),
        findsOneWidget,
      );
      expect(find.text('Giulia Rossi'), findsOneWidget);
      // Las semanas del pedido, cada 7 días desde la preferida, todas libres.
      expect(tester.widget<Text>(byKey('booking-weeks-value')).data, '4');
      for (final (i, date) in [
        'lun 23 nov',
        'lun 30 nov',
        'lun 7 dic',
        'lun 14 dic',
      ].indexed) {
        expect(find.text('Settimana ${i + 1} · $date'), findsOneWidget);
        expect(
          tester.widget<Text>(byKey('booking-week-$i-status')).data,
          'Libero',
        );
      }
      // La llegada que sugiere el servidor, elegida.
      expect(
        tester.widget<ChoiceChip>(byKey('booking-start-10:00')).selected,
        isTrue,
      );
      expect(
        tester.widget<ChoiceChip>(byKey('booking-start-10:30')).selected,
        isFalse,
      );
      expect(
        find.text('Suggerita: 10:00 (apertura più il tempo della spesa).'),
        findsOneWidget,
      );
      // Minutos de la estimación y su precio, con lo que queda por semana.
      expect(tester.widget<Text>(byKey('booking-cook-value')).data, '180 min');
      expect(priceText(tester), '560');
      // intl separa el número del € con un espacio duro (U+00A0).
      expect(find.text('= 140,00 € a settimana'), findsOneWidget);
      expect(find.text('Conferma 4 settimane'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNotNull);
      // El campo del precio, con letra de 16 px o más.
      expectReadableInputs(tester);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in const [Locale('es', 'ES'), Locale('it', 'IT')]) {
    testWidgets(
      'a 375×667 la acción principal queda en el tercio inferior, también con el teclado (${locale.languageCode})',
      (tester) async {
        await openSheet(
          tester,
          size: const Size(375, 667),
          locale: locale,
          open: false,
        );
        // En el detalle, «Conferma prenotazione» ya está abajo.
        final detailAction = byKey('action-confirm-booking');
        expect(detailAction.hitTestable(), findsOneWidget);
        expect(tester.getCenter(detailAction).dy, greaterThan(667 * 2 / 3));
        expect(tester.getSize(detailAction).height, greaterThanOrEqualTo(48));

        await tester.tap(detailAction);
        await tester.pumpAndSettle();
        final confirm = byKey('booking-confirm');
        expect(confirm.hitTestable(), findsOneWidget);
        expect(tester.getCenter(confirm).dy, greaterThan(667 * 2 / 3));
        expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
        // Objetivos de 48 dp: los botones de las semanas y los contadores.
        expect(
          tester.getSize(byKey('booking-week-0-edit')).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(byKey('booking-weeks-increment')).height,
          greaterThanOrEqualTo(48),
        );

        // Con el teclado abierto (unos 300 pt en un iPhone SE), el botón sigue a
        // la vista, arriba del teclado.
        await tester.ensureVisible(byKey('booking-price'));
        await tester.tap(byKey('booking-price'));
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(667 - 300));
        expectReadableInputs(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cada semana muestra lo que dice el servidor; con un choque no deja confirmar',
    (tester) async {
      await openSheet(
        tester,
        configure: (bookings) {
          bookings.statuses[mondays[1]] = BookingDayStatus.blocked;
          bookings.statuses[mondays[2]] = BookingDayStatus.outside;
          bookings.closedDays.add(mondays[3]);
        },
      );
      String status(int week) =>
          tester.widget<Text>(byKey('booking-week-$week-status')).data!;
      expect(status(0), 'Libero');
      expect(status(1), 'Giorno bloccato');
      expect(status(2), 'Fuori dal tuo orario');
      expect(status(3), 'Non lavori quel giorno');
      // Los avisos no impiden confirmar.
      expect(confirmButton(tester).onPressed, isNotNull);
    },
  );

  testWidgets(
    'otra hora de llegada: el chip queda elegido y el servidor lo vuelve a comprobar; un choque lo frena',
    (tester) async {
      final app = await openSheet(tester);
      app.bookings.statuses[mondays[0]] = BookingDayStatus.busy;

      await tester.tap(byKey('booking-start-11:00'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<ChoiceChip>(byKey('booking-start-11:00')).selected,
        isTrue,
      );
      expect(app.bookings.dryRuns.last.start, const ClockTime.hm(11, 0));
      expect(
        tester.widget<Text>(byKey('booking-week-0-status')).data,
        "Si sovrappone a un'altra sessione",
      );
      expect(confirmButton(tester).onPressed, isNull);
    },
  );

  testWidgets(
    '«+» suma una semana 7 días después; el precio y el botón lo siguen',
    (tester) async {
      await openSheet(tester);
      await tester.tap(byKey('booking-weeks-increment'));
      await tester.pumpAndSettle();

      expect(find.text('Settimana 5 · lun 21 dic'), findsOneWidget);
      expect(priceText(tester), '700', reason: '5 × 140 €');
      expect(find.text('Conferma 5 settimane'), findsOneWidget);
    },
  );

  testWidgets('cambiar una fecha con el calendario', (tester) async {
    final app = await openSheet(tester);
    await tester.tap(byKey('booking-week-2-edit'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(CalendarDatePicker),
        matching: find.text('9'),
      ),
    );
    final ok = MaterialLocalizations.of(
      tester.element(find.byType(DatePickerDialog)),
    ).okButtonLabel;
    await tester.tap(find.text(ok));
    await tester.pumpAndSettle();

    expect(find.text('Settimana 3 · mer 9 dic'), findsOneWidget);
    expect(app.bookings.dryRuns.last.dates[2], CalendarDate(2026, 12, 9));
  });

  testWidgets(
    'sin precio automático el campo pide el precio; al escribirlo deja confirmar',
    (tester) async {
      await openSheet(
        tester,
        request: weekly(
          weeks: 2,
          estimate: const RequestEstimate(
            weeks: 2,
            portions: 30,
            cookMinutes: 240,
            autoPrice: false,
            reason: NoAutoPriceReason.people,
            groceriesEstCents: 9450,
            maxPeople: 5,
          ),
        ),
      );
      expect(priceText(tester), isEmpty);
      expect(find.text('Scrivi il prezzo che hai concordato.'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNull);

      await tester.enterText(byKey('booking-price'), '500');
      await tester.pumpAndSettle();
      expect(find.text('= 250,00 € a settimana'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNotNull);

      await tester.enterText(byKey('booking-price'), '500,505');
      await tester.pumpAndSettle();
      expect(find.text('Al massimo 100.000,00 €.'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNull);
      expectReadableInputs(tester);
    },
  );

  testWidgets(
    'confirmar: las fechas creadas y el WhatsApp en el idioma de la clienta; «Listo» vuelve al detalle, ya aceptado',
    (tester) async {
      // La interfaz en español; la clienta, italiana.
      final app = await openSheet(tester, locale: const Locale('es', 'ES'));

      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();

      final sent = app.bookings.confirmations.single;
      expect(sent.serviceTotalCents, 56000);
      expect(sent.start, const ClockTime.hm(10, 0));
      expect(sent.requestKey, isNotNull);

      expect(find.widgetWithText(AppBar, 'Reserva confirmada'), findsOneWidget);
      expect(
        find.text(
          '4 sesiones creadas. En 1 o 2 minutos la web deja de ofrecer esos horarios.',
        ),
        findsOneWidget,
      );
      // En español la fecha corta lleva coma: «lun, 23 nov».
      expect(find.text('Semana 1 · lun, 23 nov · 10:00'), findsOneWidget);
      expect(find.text('Semana 4 · lun, 14 dic · 10:00'), findsOneWidget);
      expect(find.text('Servicio, 4 semanas: 560,00 €'), findsOneWidget);

      await tester.tap(byKey('booking-whatsapp'));
      await tester.pumpAndSettle();
      final whatsApp = app.launcher.launched.single;
      expect(whatsApp.host, 'wa.me');
      expect(whatsApp.path, '/393331234567');
      expect(
        whatsApp.queryParameters['text'],
        startsWith(
          'Ciao Giulia, sono Evelyn di Radici. Ti confermo le 4 sessioni di cucina',
        ),
      );

      await tester.tap(byKey('booking-done-close'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsNothing);
      expect(find.text('Aceptada'), findsOneWidget);
      expect(byKey('action-confirm-booking'), findsNothing);
    },
  );

  testWidgets(
    'mientras envía: el botón queda deshabilitado y la hoja no se cierra',
    (tester) async {
      final app = await openSheet(
        tester,
        configure: (b) => b.pendingConfirm = Completer<void>(),
      );

      await tester.tap(byKey('booking-confirm'));
      await tester.pump();
      expect(confirmButton(tester).onPressed, isNull);
      expect(find.text('Conferma in corso…'), findsOneWidget);
      expect(
        tester.widget<IconButton>(byKey('booking-close')).onPressed,
        isNull,
      );
      await tester.tap(byKey('booking-confirm'), warnIfMissed: false);
      await tester.pump();
      expect(app.bookings.confirmations, hasLength(1));
      // La hoja no cambia mientras tanto: ni las semanas ni el precio.
      await tester.tap(byKey('booking-weeks-increment'), warnIfMissed: false);
      await tester.pump();
      expect(tester.widget<Text>(byKey('booking-weeks-value')).data, '4');
      expect(tester.widget<TextField>(byKey('booking-price')).readOnly, isTrue);

      app.bookings.pendingConfirm!.complete();
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(AppBar, 'Prenotazione confermata'),
        findsOneWidget,
      );
    },
  );

  testWidgets('un choque al confirmar dice qué día choca y no crea nada', (
    tester,
  ) async {
    final app = await openSheet(tester);
    app.bookings
      ..confirmFailure = BookingFailure(
        BookingFailureKind.slotTaken,
        date: mondays[1],
      )
      ..statuses[mondays[1]] = BookingDayStatus.busy;

    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(byKey('booking-failure')).data,
      "La settimana del lun 30 nov si sovrappone a un'altra sessione: non è stato "
      "creato nulla. Cambia quella data o l'ora.",
    );
    expect(
      tester.widget<Text>(byKey('booking-week-1-status')).data,
      "Si sovrappone a un'altra sessione",
    );
    expect(confirmButton(tester).onPressed, isNull);
    expect(find.byType(ConfirmBookingScreen), findsOneWidget);
  });

  testWidgets(
    'sin conexión al confirmar: avisa y se reintenta con la misma clave',
    (tester) async {
      final app = await openSheet(tester);
      app.bookings.confirmFailure = const BookingFailure(
        BookingFailureKind.unavailable,
      );
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Non è stato possibile confermare. Controlla la connessione e riprova: '
          'se era già confermata, non si duplica.',
        ),
        findsOneWidget,
      );

      app.bookings.confirmFailure = null;
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      final keys = app.bookings.confirmations.map((c) => c.requestKey).toList();
      expect(keys, hasLength(2));
      expect(keys.first, keys.last);
      expect(
        find.widgetWithText(AppBar, 'Prenotazione confermata'),
        findsOneWidget,
      );
    },
  );

  testWidgets('la X cierra la hoja sin crear nada', (tester) async {
    final app = await openSheet(tester);
    await tester.tap(byKey('booking-close'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmBookingScreen), findsNothing);
    expect(app.bookings.confirmations, isEmpty);
    expect(byKey('action-confirm-booking'), findsOneWidget);
  });

  testWidgets(
    'pantalla ancha: el contenido no pasa de 720 y la barra de abajo tampoco',
    (tester) async {
      await openSheet(tester, size: const Size(1200, 900));
      expect(
        tester.getSize(byKey('booking-form')).width,
        lessThanOrEqualTo(720),
      );
      expect(
        tester.getSize(byKey('booking-confirm')).width,
        lessThanOrEqualTo(720),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in const [Locale('es'), Locale('en')]) {
    testWidgets('teléfono angosto sin desbordes (${locale.languageCode})', (
      tester,
    ) async {
      await openSheet(tester, size: const Size(320, 640), locale: locale);
      expect(tester.takeException(), isNull);
      expect(byKey('booking-confirm').hitTestable(), findsOneWidget);
    });
  }
}

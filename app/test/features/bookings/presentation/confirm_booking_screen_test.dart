// Hoja «Conferma prenotazione» en la app, desde el detalle de un pedido nuevo:
// lo prellenado, lo que dice el servidor de cada semana, el campo del precio
// con letra de 16 px (si no, iOS hace zoom) y teclado numérico, la acción
// principal en el tercio inferior a 375×667 con el precio que se confirma (o
// lo que lo impide) a la vista arriba del botón, el envío con todo
// deshabilitado, la confirmación sin respuesta que se reintenta con lo mismo
// y, al confirmar, el WhatsApp en el idioma de la clienta.
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

/// intl separa el número del € con un espacio duro.
const String _nbsp = ' ';

void main() {
  final monday = CalendarDate(2026, 11, 23);
  final mondays = weeklyDates(monday, 4);

  ChefRequest weekly({
    int weeks = 4,
    RequestEstimate? estimate = fourWeeksEstimate,
    String? phone = '+39 333 123 4567',
  }) => buildRequest(
    weeks: weeks,
    preferredDate: monday,
    estimate: estimate,
    seenAt: testNow,
    phone: phone,
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

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(byKey(key)).data!;

  bool priceFocused(WidgetTester tester) =>
      tester.widget<TextField>(byKey('booking-price')).focusNode!.hasFocus;

  /// Lleva [key] a la vista (la barra de abajo tapa parte del formulario) y
  /// lo toca.
  Future<void> tapInForm(WidgetTester tester, String key) async {
    await tester.ensureVisible(byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(byKey(key));
    await tester.pumpAndSettle();
  }

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
      expect(textOf(tester, 'booking-weeks-value'), '4');
      expect(find.text('Date'), findsOneWidget);
      for (final (i, date) in [
        'lun 23 nov',
        'lun 30 nov',
        'lun 7 dic',
        'lun 14 dic',
      ].indexed) {
        expect(find.text('Settimana ${i + 1} · $date'), findsOneWidget);
        expect(textOf(tester, 'booking-week-$i-status'), 'Libero');
      }
      expect(
        find.text(
          'Se cambi la prima data si spostano tutte; le altre si cambiano una alla volta.',
        ),
        findsOneWidget,
      );
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
      expect(textOf(tester, 'booking-cook-value'), '180 min');
      // «Tempo in cucina» una sola vez: la fila, sin otro título igual.
      expect(find.text('Tempo in cucina'), findsOneWidget);
      expect(priceText(tester), '560');
      expect(find.text('Prezzo del servizio, tutte le settimane'), findsOneWidget);
      expect(find.text('= 140,00$_nbsp€ a settimana'), findsOneWidget);
      // Arriba del botón, el precio que se va a confirmar.
      expect(
        textOf(tester, 'booking-summary'),
        'Servizio 560,00$_nbsp€ · 140,00$_nbsp€ a settimana · arrivo 10:00',
      );
      expect(find.text('Conferma 4 settimane'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNotNull);
      // El campo del precio, con letra de 16 px o más y teclado numérico.
      expectReadableInputs(tester);
      expect(
        tester.widget<TextField>(byKey('booking-price')).keyboardType,
        const TextInputType.numberWithOptions(decimal: true),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (locale, summary) in [
    (
      const Locale('es', 'ES'),
      'Servicio 560,00$_nbsp€ · 140,00$_nbsp€ por semana · llegada 10:00',
    ),
    (
      const Locale('it', 'IT'),
      'Servizio 560,00$_nbsp€ · 140,00$_nbsp€ a settimana · arrivo 10:00',
    ),
  ]) {
    testWidgets(
      'a 375×667 la acción principal queda en el tercio inferior, con el precio que se confirma arriba, también con el teclado (${locale.languageCode})',
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
        // El campo del precio queda abajo, fuera de la vista: el precio que se
        // va a confirmar (después ninguna ruta lo cambia), lo que queda por
        // semana y la llegada se ven en la barra, arriba del botón.
        final summaryLine = byKey('booking-summary');
        expect(summaryLine.hitTestable(), findsOneWidget);
        expect(textOf(tester, 'booking-summary'), summary);
        expect(
          tester.getRect(summaryLine).top,
          greaterThanOrEqualTo(tester.getRect(byKey('booking-form')).bottom),
        );
        expect(
          tester.getRect(summaryLine).bottom,
          lessThanOrEqualTo(tester.getRect(confirm).top),
        );
        // Objetivos de 48 dp: cada semana, los contadores y «Cambiar».
        expect(
          tester.getSize(byKey('booking-week-0')).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(byKey('booking-weeks-increment')).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(byKey('booking-edit-price')).height,
          greaterThanOrEqualTo(48),
        );

        // Con el teclado abierto (unos 300 pt en un iPhone SE), el botón y el
        // precio siguen a la vista, arriba del teclado.
        await tester.ensureVisible(byKey('booking-price'));
        await tester.tap(byKey('booking-price'));
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(667 - 300));
        expect(summaryLine.hitTestable(), findsOneWidget);
        expectReadableInputs(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a 375×667, «Cambiar» lleva al precio y le da el foco; lo que se escribe se ve en la barra',
    (tester) async {
      await openSheet(
        tester,
        size: const Size(375, 667),
        locale: const Locale('es', 'ES'),
      );
      expect(priceFocused(tester), isFalse);

      await tester.tap(byKey('booking-edit-price'));
      await tester.pumpAndSettle();
      expect(byKey('booking-price').hitTestable(), findsOneWidget);
      expect(priceFocused(tester), isTrue);

      await tester.enterText(byKey('booking-price'), '600');
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'booking-summary'),
        'Servicio 600,00$_nbsp€ · 150,00$_nbsp€ por semana · llegada 10:00',
      );
    },
  );

  testWidgets(
    'a 375×667 sin precio automático, la barra dice que falta el precio y «Ver» lleva al campo',
    (tester) async {
      await openSheet(
        tester,
        size: const Size(375, 667),
        locale: const Locale('es', 'ES'),
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
      expect(confirmButton(tester).onPressed, isNull);
      // El motivo se ve sin desplazar, junto al botón gris.
      final blocker = byKey('booking-blocker');
      expect(blocker.hitTestable(), findsOneWidget);
      expect(textOf(tester, 'booking-blocker'), 'Falta el precio del servicio.');
      expect(byKey('booking-summary'), findsNothing);

      await tester.tap(byKey('booking-blocker-show'));
      await tester.pumpAndSettle();
      expect(byKey('booking-price').hitTestable(), findsOneWidget);
      expect(priceFocused(tester), isTrue);

      await tester.enterText(byKey('booking-price'), '500');
      await tester.pumpAndSettle();
      expect(byKey('booking-blocker'), findsNothing);
      expect(
        textOf(tester, 'booking-summary'),
        'Servicio 500,00$_nbsp€ · 250,00$_nbsp€ por semana · llegada 10:00',
      );
      expect(confirmButton(tester).onPressed, isNotNull);
    },
  );

  testWidgets(
    'a 375×667 con 8 semanas y un choque en la sexta, la barra lo dice y «Ver» la trae a la vista',
    (tester) async {
      final eight = weeklyDates(monday, 8);
      await openSheet(
        tester,
        size: const Size(375, 667),
        locale: const Locale('es', 'ES'),
        request: weekly(
          weeks: 8,
          estimate: fourWeeksEstimate.copyWith(weeks: 8, serviceCents: 112000),
        ),
        configure: (b) => b.statuses[eight[5]] = BookingDayStatus.busy,
      );
      expect(confirmButton(tester).onPressed, isNull);
      expect(
        textOf(tester, 'booking-blocker'),
        'Semana 6 · Choca con otra sesión: cambia esa fecha o la hora.',
      );
      expect(byKey('booking-blocker').hitTestable(), findsOneWidget);
      // La sexta semana está abajo, fuera de la vista.
      expect(byKey('booking-week-5').hitTestable(), findsNothing);

      await tester.tap(byKey('booking-blocker-show'));
      await tester.pumpAndSettle();
      expect(byKey('booking-week-5').hitTestable(), findsOneWidget);
      expect(textOf(tester, 'booking-week-5-status'), 'Choca con otra sesión');
    },
  );

  testWidgets(
    'con el teclado abierto, la ayuda del precio queda a la vista arriba de la barra',
    (tester) async {
      await openSheet(
        tester,
        size: const Size(375, 667),
        locale: const Locale('es', 'ES'),
      );
      await tester.ensureVisible(byKey('booking-price'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('booking-price'));
      await tester.pump();
      // Teclado decimal más la barra de Safari.
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();

      final form = tester.getRect(byKey('booking-form'));
      final helper = tester.getRect(find.text('= 140,00$_nbsp€ por semana'));
      expect(helper.top, greaterThanOrEqualTo(form.top));
      expect(helper.bottom, lessThanOrEqualTo(form.bottom));
    },
    // /gestione/ en el iPhone corre como iOS, donde el margen de siempre (20)
    // dejaba la ayuda tapada.
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

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
      expect(textOf(tester, 'booking-week-0-status'), 'Libero');
      expect(textOf(tester, 'booking-week-1-status'), 'Giorno bloccato');
      expect(textOf(tester, 'booking-week-2-status'), 'Fuori dal tuo orario');
      expect(textOf(tester, 'booking-week-3-status'), 'Non lavori quel giorno');
      // Los avisos no impiden confirmar.
      expect(confirmButton(tester).onPressed, isNotNull);
      expect(
        find.text(
          'Gli avvisi non impediscono di confermare, una sovrapposizione sì.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'otra hora de llegada: el chip queda elegido y el servidor lo vuelve a comprobar; un choque lo frena',
    (tester) async {
      final app = await openSheet(tester);
      app.bookings.statuses[mondays[0]] = BookingDayStatus.busy;

      await tapInForm(tester, 'booking-start-11:00');

      expect(
        tester.widget<ChoiceChip>(byKey('booking-start-11:00')).selected,
        isTrue,
      );
      expect(app.bookings.dryRuns.last.start, const ClockTime.hm(11, 0));
      expect(
        textOf(tester, 'booking-week-0-status'),
        "Si sovrappone a un'altra sessione",
      );
      expect(confirmButton(tester).onPressed, isNull);
      expect(
        textOf(tester, 'booking-blocker'),
        "Settimana 1 · Si sovrappone a un'altra sessione: cambia quella data o l'ora.",
      );
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
      expect(
        textOf(tester, 'booking-summary'),
        'Servizio 700,00$_nbsp€ · 140,00$_nbsp€ a settimana · arrivo 10:00',
      );
      expect(find.text('Conferma 5 settimane'), findsOneWidget);
    },
  );

  testWidgets('cambiar una fecha con el calendario (toda la fila)', (
    tester,
  ) async {
    final app = await openSheet(tester);
    await tapInForm(tester, 'booking-week-2');
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(find.text('Cambia la data della settimana 3'), findsOneWidget);

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
    'cada semana es un solo objetivo para el lector de pantalla, con la pista de cambiar la fecha',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await openSheet(tester);
      expect(
        tester.getSemantics(byKey('booking-week-1')),
        isSemantics(
          hint: 'Cambia la data della settimana 2',
          hasTapAction: true,
        ),
      );
      // El ícono de la derecha ya no es otro botón con la misma acción.
      expect(find.bySemanticsLabel('Cambia la data della settimana 2'), findsNothing);
      expect(
        find.descendant(
          of: byKey('booking-week-1'),
          matching: find.byType(IconButton),
        ),
        findsNothing,
      );
      semantics.dispose();
    },
  );

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
      expect(textOf(tester, 'booking-blocker'), 'Manca il prezzo del servizio.');
      expect(confirmButton(tester).onPressed, isNull);

      await tester.enterText(byKey('booking-price'), '500');
      await tester.pumpAndSettle();
      expect(find.text('= 250,00$_nbsp€ a settimana'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNotNull);

      await tester.enterText(byKey('booking-price'), '500,505');
      await tester.pumpAndSettle();
      expect(find.text('Al massimo 100.000,00$_nbsp€.'), findsOneWidget);
      expect(
        textOf(tester, 'booking-blocker'),
        'Il prezzo supera il massimo di 100.000,00$_nbsp€.',
      );
      expect(confirmButton(tester).onPressed, isNull);

      await tester.enterText(byKey('booking-price'), '50,0,5');
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'booking-blocker'),
        'Il prezzo non è un importo valido.',
      );
      expectReadableInputs(tester);
    },
  );

  testWidgets(
    'una sola fecha (un evento): sin «Settimana 1» ni «las demás», y el precio sin «tutte le settimane»',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final app = await openSheet(
        tester,
        request: buildRequest(
          type: RequestType.extra,
          preferredDate: monday,
          seenAt: testNow,
          estimate: const RequestEstimate(
            weeks: 1,
            portions: 16,
            cookMinutes: 210,
            autoPrice: false,
            reason: NoAutoPriceReason.extra,
          ),
        ),
      );
      expect(byKey('booking-weeks-value'), findsNothing);
      expect(find.text('Data'), findsOneWidget);
      expect(find.text('lun 23 nov'), findsOneWidget);
      expect(find.textContaining('Settimana'), findsNothing);
      expect(find.textContaining('Se cambi la prima data'), findsNothing);
      expect(
        find.text(
          'Gli avvisi non impediscono di confermare, una sovrapposizione sì.',
        ),
        findsOneWidget,
      );
      expect(find.text('Prezzo del servizio'), findsOneWidget);
      expect(
        tester.getSemantics(byKey('booking-week-0')),
        isSemantics(hint: 'Cambia la data'),
      );

      await tester.enterText(byKey('booking-price'), '200');
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'booking-summary'),
        'Servizio 200,00$_nbsp€ · arrivo 10:00',
      );
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(app.bookings.confirmations.single.dates, [monday]);
      expect(find.text('lun 23 nov · 10:00'), findsOneWidget);
      expect(find.textContaining('Settimana'), findsNothing);
      semantics.dispose();
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
      // La web ofrece días, no horarios.
      expect(
        find.text(
          '4 sesiones creadas. En 1 o 2 minutos la web deja de ofrecer esos días.',
        ),
        findsOneWidget,
      );
      expect(byKey('booking-done-duplicate'), findsNothing);
      // En español la fecha corta lleva coma: «lun, 23 nov».
      expect(find.text('Semana 1 · lun, 23 nov · 10:00'), findsOneWidget);
      expect(find.text('Semana 4 · lun, 14 dic · 10:00'), findsOneWidget);
      expect(find.text('Servicio, 4 semanas: 560,00$_nbsp€'), findsOneWidget);

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
    'sin un teléfono válido: confirmada igual, lo dice y el WhatsApp queda deshabilitado',
    (tester) async {
      await openSheet(tester, request: weekly(phone: '612 345 678'));
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();

      expect(byKey('booking-done'), findsOneWidget);
      expect(
        textOf(tester, 'booking-no-phone'),
        'Senza un numero valido non si può mandare su WhatsApp.',
      );
      expect(
        tester.widget<FilledButton>(byKey('booking-whatsapp')).onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'mientras envía: todo queda deshabilitado y ni la X ni el «atrás» del sistema cierran la hoja',
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
      // La hoja no cambia mientras tanto: ni las semanas, ni las fechas, ni la
      // hora, ni el precio (que sigue a la vista en la barra).
      await tester.tap(byKey('booking-weeks-increment'), warnIfMissed: false);
      await tester.pump();
      expect(textOf(tester, 'booking-weeks-value'), '4');
      expect(tester.widget<ListTile>(byKey('booking-week-0')).enabled, isFalse);
      expect(
        tester.widget<ChoiceChip>(byKey('booking-start-10:30')).onSelected,
        isNull,
      );
      expect(tester.widget<TextField>(byKey('booking-price')).readOnly, isTrue);
      expect(
        textOf(tester, 'booking-summary'),
        'Servizio 560,00$_nbsp€ · 140,00$_nbsp€ a settimana · arrivo 10:00',
      );
      expect(
        tester.widget<TextButton>(byKey('booking-edit-price')).onPressed,
        isNull,
      );

      // El «atrás» del sistema (Android, o deslizar en iOS) tampoco la cierra.
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);

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
      textOf(tester, 'booking-failure'),
      "La settimana del lun 30 nov si sovrappone a un'altra sessione: non è stato "
      "creato nulla. Cambia quella data o l'ora.",
    );
    expect(
      textOf(tester, 'booking-week-1-status'),
      "Si sovrappone a un'altra sessione",
    );
    expect(confirmButton(tester).onPressed, isNull);
    expect(find.byType(ConfirmBookingScreen), findsOneWidget);
  });

  testWidgets(
    'el lector de pantalla anuncia la falla y la confirmación (liveRegion)',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final app = await openSheet(
        tester,
        configure: (b) => b.confirmFailure = BookingFailure(
          BookingFailureKind.slotTaken,
          date: mondays[1],
        ),
      );
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(byKey('booking-failure')),
        isSemantics(isLiveRegion: true),
      );

      // El dryRun que sigue dice que está libre: se puede volver a confirmar.
      app.bookings.confirmFailure = null;
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(byKey('booking-done-body')),
        isSemantics(isLiveRegion: true),
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'sin respuesta al confirmar: nada se puede cambiar y «Riprova» manda lo mismo; si ya había quedado guardada, no se duplica',
    (tester) async {
      // La base la guarda pero la respuesta se pierde.
      final app = await openSheet(
        tester,
        configure: (b) => b.loseNextConfirmResponse = true,
      );
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'booking-failure'),
        'Non è stato possibile confermare. Controlla la connessione e riprova '
        'con gli stessi dati: se era già confermata, non si duplica.',
      );
      expect(find.widgetWithText(FilledButton, 'Riprova'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNotNull);
      // Lo que se reintenta, a la vista; y nada se puede cambiar.
      expect(
        textOf(tester, 'booking-summary'),
        'Servizio 560,00$_nbsp€ · 140,00$_nbsp€ a settimana · arrivo 10:00',
      );
      expect(
        tester.widget<IconButton>(byKey('booking-weeks-increment')).onPressed,
        isNull,
      );
      expect(tester.widget<ListTile>(byKey('booking-week-0')).enabled, isFalse);
      expect(
        tester.widget<ChoiceChip>(byKey('booking-start-10:30')).onSelected,
        isNull,
      );
      expect(tester.widget<TextField>(byKey('booking-price')).readOnly, isTrue);
      // Cerrar la hoja sí se puede (para empezar de nuevo).
      expect(
        tester.widget<IconButton>(byKey('booking-close')).onPressed,
        isNotNull,
      );

      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      final sent = app.bookings.confirmations;
      expect(sent, hasLength(2));
      expect(sent.last, sent.first, reason: 'la misma clave y los mismos datos');
      expect(
        find.widgetWithText(AppBar, 'Prenotazione confermata'),
        findsOneWidget,
      );
      expect(
        textOf(tester, 'booking-done-duplicate'),
        'Era già confermata: non si è duplicato nulla.',
      );
      expect(
        tester.widget<FilledButton>(byKey('booking-whatsapp')).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'ya confirmada desde otro dispositivo con las mismas fechas y otro precio: avisa que vale lo guardado',
    (tester) async {
      final app = await openSheet(tester);
      // Otro dispositivo confirma las mismas fechas y hora con 500 €.
      await app.bookings.createBooking(
        BookingRequest(
          requestId: 'req-1',
          dates: mondays,
          start: const ClockTime.hm(10, 0),
          cookMinutes: 180,
          serviceTotalCents: 50000,
          requestKey: 'other-device',
        ),
      );

      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'booking-done-differs'),
        'Era già confermata con altri dati: qui sotto c\'è quello che è stato '
        'salvato, non quello inserito qui.',
      );
      expect(byKey('booking-done-duplicate'), findsNothing);
      expect(find.text('Servizio, 4 settimane: 500,00$_nbsp€'), findsOneWidget);
    },
  );

  testWidgets(
    'un reintento de una reserva ya guardada con lo mismo: no se duplicó nada',
    (tester) async {
      await openSheet(tester, configure: (b) => b.duplicate = true);
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(byKey('booking-done-duplicate'), findsOneWidget);
      expect(byKey('booking-done-differs'), findsNothing);
    },
  );

  testWidgets(
    'si no se pudieron comprobar las fechas: lo dice, deja confirmar y «Riprova» lo vuelve a pedir',
    (tester) async {
      final app = await openSheet(
        tester,
        configure: (b) => b.checksFailure = const BookingFailure(
          BookingFailureKind.unavailable,
        ),
      );
      expect(
        textOf(tester, 'booking-checks-failed'),
        'Non è stato possibile verificare le date. Puoi confermare lo stesso: '
        'il server le ricontrolla.',
      );
      expect(byKey('booking-week-0-status'), findsNothing);
      expect(confirmButton(tester).onPressed, isNotNull);

      app.bookings.checksFailure = null;
      await tapInForm(tester, 'booking-checks-retry');
      expect(byKey('booking-checks-failed'), findsNothing);
      expect(textOf(tester, 'booking-week-0-status'), 'Libero');
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
      expect(byKey('booking-summary').hitTestable(), findsOneWidget);
    });
  }
}

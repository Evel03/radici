// El presupuesto en el detalle del pedido (SPEC 5.8, «Presupuesto en la
// app»): en un pedido nuevo, «Prepara il preventivo» y «Conferma senza
// preventivo» abajo; con un presupuesto, su bloque en cada estado (borrador,
// mandado, cambios pedidos con el mensaje de la clienta, cambiado sin
// reenviar, aceptado, rechazado, retirado o vencido) con sus semanas, el
// total y lo que se puede hacer en cada uno: «Invia» abajo cuando es lo que
// falta (o por qué todavía no), otro precio con su reparto exacto y
// retirarlo con confirmación. Las horas, de Roma.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/week_menu/presentation/menu_send_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/menu_send_fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/quote_fakes.dart';
import '../../../support/quote_fixtures.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      plainSpaces(tester.widget<Text>(byKey(key)).data!);

  String buttonText(WidgetTester tester, String key) => plainSpaces(
    tester
        .widget<Text>(
          find.descendant(of: byKey(key), matching: find.byType(Text)),
        )
        .data!,
  );

  VoidCallback? onPressedOf(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(byKey(key)).onPressed;

  Future<void> tapVisible(WidgetTester tester, String key) async {
    await tester.ensureVisible(byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(byKey(key));
    await tester.pumpAndSettle();
  }

  ChefRequest weekly({RequestStatus status = RequestStatus.newRequest}) =>
      buildRequest(weeks: 4, status: status, seenAt: testNow);

  /// Las semanas `held` del presupuesto también como sesiones (sus fichas).
  List<CookingSession> heldWeeks(List<QuoteSession> weeks) => [
    for (final week in weeks)
      buildSession(
        id: week.id,
        date: week.date,
        start: week.start,
        serviceCents: week.serviceCents,
        status: week.status,
        requestId: 'req-1',
        requestStatus: RequestStatus.quoted,
      ),
  ];

  /// El detalle del pedido `req-1` con [quote] (y sus semanas como sesiones)
  /// y el menú de la semana 1 ([weekOneMenu], por defecto guardado con un
  /// plato).
  Future<ChefApp> openDetail(
    WidgetTester tester, {
    ChefRequest? request,
    RequestQuote? quote,
    bool weekOneMenu = true,
  }) async {
    final requests = FakeChefRequestsRepository([request ?? weekly()]);
    final sessions = FakeSessionsRepository(
      quote == null ? const [] : heldWeeks(quote.sessions),
    );
    final menus = FakeSessionMenusRepository(
      menus: {if (weekOneMenu) quoteSessionId(1): savedLasagneMenu(version: 2)},
      statuses: {
        for (var w = 1; w <= 4; w++) quoteSessionId(w): SessionStatus.held,
      },
    );
    return pumpChefApp(
      tester,
      requests: requests,
      sessions: sessions,
      recipes: FakeRecipesRepository(sampleRecipes()),
      menus: menus,
      menuSends: FakeMenuSendsRepository(menus: menus),
      quotes: FakeQuotesRepository(
        requests: requests,
        sessions: sessions,
        quotes: [?quote],
      ),
      location: '/richieste/req-1',
      // Todo el detalle a la vista: la lista arma solo lo que se ve.
      size: const Size(400, 3000),
    );
  }

  group('un pedido nuevo sin presupuesto', () {
    testWidgets(
      'abajo, «Prepara il preventivo» (la principal, a la derecha) y «Conferma senza preventivo»; sin bloque',
      (tester) async {
        await openDetail(tester);

        expect(
          buttonText(tester, 'action-prepare-quote'),
          'Prepara il preventivo',
        );
        expect(
          buttonText(tester, 'action-confirm-booking'),
          'Conferma senza preventivo',
        );
        expect(
          tester.getCenter(byKey('action-prepare-quote')).dx,
          greaterThan(tester.getCenter(byKey('action-confirm-booking')).dx),
        );
        expect(byKey('quote-section'), findsNothing);
      },
    );

    testWidgets('«Prepara il preventivo» abre la hoja del presupuesto', (
      tester,
    ) async {
      final app = await openDetail(tester);
      await tester.tap(byKey('action-prepare-quote'));
      await tester.pumpAndSettle();

      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(
        find.widgetWithText(AppBar, 'Prepara il preventivo'),
        findsOneWidget,
      );
      expect(byKey('quote-form-intro'), findsOneWidget);
      expect(buttonText(tester, 'booking-confirm'), 'Crea il preventivo');
      // El dryRun fue a chef/quotes, no a chef/bookings.
      expect(app.quotes.dryRuns, hasLength(1));
      expect(app.bookings.calls, isEmpty);
    });

    testWidgets('«Conferma senza preventivo» abre la hoja de siempre', (
      tester,
    ) async {
      final app = await openDetail(tester);
      await tester.tap(byKey('action-confirm-booking'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(AppBar, 'Conferma prenotazione'),
        findsOneWidget,
      );
      expect(app.bookings.dryRuns, hasLength(1));
      expect(app.quotes.calls, isEmpty);
    });

    testWidgets('un pedido de cambios no tiene presupuesto', (tester) async {
      await openDetail(
        tester,
        request: buildRequest(type: RequestType.change, seenAt: testNow),
      );
      expect(byKey('action-prepare-quote'), findsNothing);
      expect(byKey('quote-section'), findsNothing);
    });
  });

  group('un borrador', () {
    testWidgets(
      'sin mandar y hasta cuándo retiene las fechas; sus semanas con la llegada y el precio, y el total',
      (tester) async {
        await openDetail(tester, quote: buildQuote());

        expect(byKey('quote-block-draft'), findsOneWidget);
        expect(
          textOf(tester, 'quote-state'),
          'Bozza non ancora inviata: le date restano bloccate fino al 23/11 alle 14:32.',
        );
        expect(
          textOf(tester, 'quote-week-${quoteSessionId(1)}-detail'),
          'Arrivo 10:00 · 140,00 €',
        );
        expect(find.text('Settimana 1 · lun 30 nov'), findsOneWidget);
        expect(find.text('Settimana 4 · lun 21 dic'), findsOneWidget);
        expect(textOf(tester, 'quote-total'), '560,00 €');
        // Con uno abierto no se prepara otro; confirmar sin presupuesto sigue
        // (la base lo retira, y la hoja lo avisa antes).
        expect(byKey('action-prepare-quote'), findsNothing);
        expect(byKey('action-confirm-booking'), findsOneWidget);
        // Lo que falta: mandarlo (abajo), con el menú de la semana 1 listo.
        expect(buttonText(tester, 'quote-send'), 'Invia il preventivo');
        expect(onPressedOf(tester, 'quote-send'), isNotNull);
        expect(buttonText(tester, 'quote-menu'), 'Modifica il menù');
        expect(byKey('quote-change-price'), findsOneWidget);
        expect(byKey('quote-withdraw'), findsOneWidget);
      },
    );

    testWidgets(
      'sin el menú de la semana 1: «Invia» deshabilitado con el porqué y «Prepara il menù della settimana 1»',
      (tester) async {
        await openDetail(tester, quote: buildQuote(), weekOneMenu: false);

        expect(onPressedOf(tester, 'quote-send'), isNull);
        expect(
          textOf(tester, 'quote-send-needs-menu'),
          'Manca il menù della settimana 1: parte insieme al preventivo.',
        );
        expect(byKey('quote-menu-missing'), findsOneWidget);
        expect(
          buttonText(tester, 'quote-menu'),
          'Prepara il menù della settimana 1',
        );
      },
    );

    testWidgets(
      '«Invia il preventivo» abre la vista previa del menú de la semana 1, con el presupuesto arriba del mensaje',
      (tester) async {
        final app = await openDetail(tester, quote: buildQuote());
        app.menuSends.previewQuotes[quoteSessionId(1)] = testPreviewQuote;

        await tester.tap(byKey('quote-send'));
        await tester.pumpAndSettle();

        expect(find.byType(MenuSendScreen), findsOneWidget);
        expect(app.menuSends.previews.single.sessionId, quoteSessionId(1));
        expect(app.menuSends.previews.single.menuVersion, 2);
        expect(find.text('Preventivo (versione 1)'), findsOneWidget);
        expect(
          textOf(tester, 'menu-send-quote-week-0'),
          'Settimana 1 · lun 30 nov · Arrivo 10:00 · 140,00 €',
        );
        expect(textOf(tester, 'menu-send-quote-total'), '280,00 €');
        expect(
          textOf(tester, 'menu-send-quote-deadline'),
          'Ha 48 ore per accettarlo da quando lo invii; intanto le date restano riservate a lei.',
        );

        await tester.tap(byKey('menu-send-submit'));
        await tester.pumpAndSettle();
        expect(byKey('menu-send-done-quote'), findsOneWidget);
        expect(
          tester.widget<Text>(byKey('menu-send-done-quote')).data,
          'Il preventivo (versione 1) è partito con il menù.',
        );
      },
    );

    testWidgets(
      'una semana abre su ficha, que avisa que moverla o cancelarla cambia el presupuesto',
      (tester) async {
        await openDetail(tester, quote: buildQuote());

        await tapVisible(tester, 'quote-week-${quoteSessionId(2)}');

        expect(find.byType(CookingSessionScreen), findsOneWidget);
        expect(byKey('session-quote-held'), findsOneWidget);
        expect(byKey('session-move'), findsOneWidget);
        expect(byKey('session-cancel'), findsOneWidget);
        // La semana 2 todavía no se manda.
        expect(byKey('session-menu-after-quote'), findsOneWidget);
      },
    );
  });

  group('mandado', () {
    testWidgets(
      'cuándo salió, qué versión y hasta cuándo puede aceptarlo; mandarlo de nuevo va en el bloque',
      (tester) async {
        await openDetail(
          tester,
          request: weekly(status: RequestStatus.quoted),
          quote: buildQuote(sent: true),
        );

        expect(byKey('quote-block-sent'), findsOneWidget);
        expect(
          textOf(tester, 'quote-state'),
          'Inviato il 22/11 alle 14:32 (versione 1).',
        );
        expect(
          textOf(tester, 'quote-valid-until'),
          'La cliente può accettarlo fino al 24/11 alle 14:32.',
        );
        expect(byKey('quote-send'), findsNothing);
        expect(buttonText(tester, 'quote-resend'), 'Invia di nuovo');
        // Abajo queda solo «Conferma senza preventivo».
        expect(
          buttonText(tester, 'action-confirm-booking'),
          'Conferma senza preventivo',
        );
        expect(byKey('action-prepare-quote'), findsNothing);
      },
    );

    testWidgets(
      'la clienta pidió cambios: su mensaje entero, qué hacer y «Invia di nuovo» abajo',
      (tester) async {
        await openDetail(
          tester,
          request: weekly(status: RequestStatus.quoted),
          quote: buildQuote(
            sent: true,
            lastSend: quoteSend(
              changesRequestedAt: DateTime.utc(2026, 11, 22, 16, 5),
              changesText: 'Preferirei il martedì.\nE niente funghi.',
            ),
          ),
        );

        expect(byKey('quote-block-changesRequested'), findsOneWidget);
        expect(
          textOf(tester, 'quote-changes'),
          'Il 22/11 alle 17:05 la cliente ha chiesto delle modifiche:',
        );
        expect(
          tester.widget<SelectableText>(byKey('quote-changes-text')).data,
          'Preferirei il martedì.\nE niente funghi.',
        );
        expect(byKey('quote-changes-hint'), findsOneWidget);
        expect(buttonText(tester, 'quote-send'), 'Invia di nuovo');
      },
    );

    testWidgets(
      'cambiado después de mandarlo: lo dice y «Invia di nuovo» abajo',
      (tester) async {
        await openDetail(
          tester,
          request: weekly(status: RequestStatus.quoted),
          quote: buildQuote(
            sent: true,
            sentTerms: termsOf(quoteSessions()),
            sessions: quoteSessions(serviceCents: 15000),
          ),
        );

        expect(byKey('quote-changed'), findsOneWidget);
        expect(
          textOf(tester, 'quote-changed'),
          "L'hai cambiato dopo averlo inviato: la cliente non può accettarlo finché non glielo rimandi.",
        );
        expect(textOf(tester, 'quote-total'), '600,00 €');
        expect(buttonText(tester, 'quote-send'), 'Invia di nuovo');
      },
    );
  });

  group('cerrado', () {
    final at = DateTime.utc(2026, 11, 23, 8, 15);

    testWidgets('aceptado: cuándo y lo que aceptó, sin acciones', (
      tester,
    ) async {
      await openDetail(
        tester,
        request: weekly(status: RequestStatus.accepted),
        quote: buildQuote(sent: true, acceptedAt: at),
      );
      expect(
        textOf(tester, 'quote-state'),
        "La cliente l'ha accettato il 23/11 alle 09:15.",
      );
      expect(textOf(tester, 'quote-total'), '560,00 €');
      expect(byKey('quote-change-price'), findsNothing);
      expect(byKey('quote-withdraw'), findsNothing);
      expect(byKey('quote-send'), findsNothing);
    });

    testWidgets('rechazado por la clienta', (tester) async {
      await openDetail(
        tester,
        request: weekly(status: RequestStatus.declined),
        quote: buildQuote(sent: true, declinedAt: at),
      );
      expect(
        textOf(tester, 'quote-state'),
        "La cliente l'ha rifiutato il 23/11 alle 09:15.",
      );
      expect(byKey('quote-withdraw'), findsNothing);
    });

    testWidgets(
      'vencido: lo dice; un borrador que venció, también (y el pedido nuevo vuelve a ofrecer los dos)',
      (tester) async {
        await openDetail(
          tester,
          request: weekly(status: RequestStatus.expired),
          quote: buildQuote(sent: true, expiredAt: at),
        );
        expect(
          textOf(tester, 'quote-state'),
          'Scaduto il 23/11 alle 09:15 senza risposta: le date vengono liberate.',
        );
      },
    );

    testWidgets(
      'un borrador retirado en un pedido nuevo: lo dice y se puede preparar otro',
      (tester) async {
        await openDetail(tester, quote: buildQuote(withdrawnAt: at));
        expect(
          textOf(tester, 'quote-state'),
          'Ritirato il 23/11 alle 09:15: le settimane bloccate sono state annullate.',
        );
        // Nunca salió: no hay semanas que mostrar (ya se liberaron).
        expect(byKey('quote-total'), findsNothing);
        expect(byKey('action-prepare-quote'), findsOneWidget);
        expect(byKey('action-confirm-booking'), findsOneWidget);
      },
    );
  });

  group('otro precio', () {
    testWidgets(
      'el precio de ahora, el reparto exacto mientras se escribe y, al guardar, que hay que mandarlo de nuevo',
      (tester) async {
        final app = await openDetail(
          tester,
          request: weekly(status: RequestStatus.quoted),
          quote: buildQuote(sent: true),
        );

        await tapVisible(tester, 'quote-change-price');
        expect(byKey('quote-price-dialog'), findsOneWidget);
        final field = tester.widget<TextField>(byKey('quote-price-field'));
        expect(field.controller!.text, '560');

        await tester.enterText(byKey('quote-price-field'), '500');
        await tester.pump();
        expect(find.text('= 125,00 € a settimana'), findsNothing);
        expect(findPlainText('= 125,00 € a settimana'), findsOneWidget);
        await tester.enterText(byKey('quote-price-field'), '500,03');
        await tester.pump();
        expect(
          findPlainText(
            'Per settimana: 125,01 € · 125,01 € · 125,01 € · 125,00 €',
          ),
          findsOneWidget,
        );
        await tester.enterText(byKey('quote-price-field'), '');
        await tester.pump();
        expect(onPressedOf(tester, 'quote-price-save'), isNull);

        await tester.enterText(byKey('quote-price-field'), '500');
        await tester.pump();
        await tester.tap(byKey('quote-price-save'));
        await tester.pumpAndSettle();

        expect(app.quotes.priceCalls, [(quoteId: testQuoteId, cents: 50000)]);
        expect(
          find.text('Prezzo cambiato: rimandalo perché la cliente lo veda.'),
          findsOneWidget,
        );
        expect(textOf(tester, 'quote-total'), '500,00 €');
        expect(byKey('quote-changed'), findsOneWidget);
        expect(buttonText(tester, 'quote-send'), 'Invia di nuovo');
      },
    );

    testWidgets('si falla, lo dice; el mismo precio no manda nada', (
      tester,
    ) async {
      final app = await openDetail(tester, quote: buildQuote());
      app.quotes.priceFailure = const QuoteFailure(QuoteFailureKind.closed);

      await tapVisible(tester, 'quote-change-price');
      await tester.tap(byKey('quote-price-save'));
      await tester.pumpAndSettle();
      expect(app.quotes.priceCalls, isEmpty);

      await tapVisible(tester, 'quote-change-price');
      await tester.enterText(byKey('quote-price-field'), '600');
      await tester.pump();
      await tester.tap(byKey('quote-price-save'));
      await tester.pumpAndSettle();
      expect(app.quotes.priceCalls, hasLength(1));
      expect(
        find.text(
          'Il preventivo non è più aperto (accettato, rifiutato, ritirato o scaduto).',
        ),
        findsOneWidget,
      );
    });
  });

  group('retirarlo', () {
    testWidgets(
      'pide confirmación; sus semanas se cancelan y el pedido vuelve a ofrecer los dos botones',
      (tester) async {
        final app = await openDetail(
          tester,
          request: weekly(status: RequestStatus.quoted),
          quote: buildQuote(sent: true),
        );

        await tapVisible(tester, 'quote-withdraw');
        expect(byKey('quote-withdraw-dialog'), findsOneWidget);
        await tester.tap(byKey('quote-withdraw-cancel'));
        await tester.pumpAndSettle();
        expect(app.quotes.withdrawCalls, isEmpty);

        await tapVisible(tester, 'quote-withdraw');
        await tester.tap(byKey('quote-withdraw-confirm'));
        await tester.pumpAndSettle();

        expect(app.quotes.withdrawCalls, [testQuoteId]);
        expect(find.text('Preventivo ritirato.'), findsOneWidget);
        expect(byKey('quote-block-withdrawn'), findsOneWidget);
        expect(app.sessions.sessions.values.map((s) => s.status).toSet(), {
          SessionStatus.cancelled,
        });
        // El pedido volvió a nuevo: se puede preparar otro.
        expect(byKey('action-prepare-quote'), findsOneWidget);
      },
    );
  });

  testWidgets('si no se puede leer el presupuesto, lo dice con «Riprova»', (
    tester,
  ) async {
    final requests = FakeChefRequestsRepository([weekly()]);
    final quotes = FakeQuotesRepository(requests: requests)
      ..fetchFailure = const QuoteFailure(QuoteFailureKind.unavailable);
    await pumpChefApp(
      tester,
      requests: requests,
      quotes: quotes,
      location: '/richieste/req-1',
      // Todo el detalle a la vista: la lista arma solo lo que se ve.
      size: const Size(400, 3000),
    );
    expect(byKey('quote-load-error'), findsOneWidget);

    quotes.fetchFailure = null;
    await tapVisible(tester, 'quote-retry');
    expect(byKey('quote-load-error'), findsNothing);
    expect(byKey('quote-section'), findsNothing);
  });

  group('confirmar sin presupuesto con uno abierto', () {
    testWidgets(
      'la hoja avisa que lo retira y, antes de confirmar, lo pregunta; al confirmar, el pedido es una reserva y el presupuesto queda retirado',
      (tester) async {
        final app = await openDetail(
          tester,
          request: weekly(status: RequestStatus.quoted),
          quote: buildQuote(sent: true),
        );

        await tester.tap(byKey('action-confirm-booking'));
        await tester.pumpAndSettle();
        expect(find.byType(ConfirmBookingScreen), findsOneWidget);
        await tester.enterText(byKey('booking-price'), '560');
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(byKey('booking-withdraws-quote')).data,
          'Questa richiesta ha un preventivo già inviato: confermando, viene ritirato, le sue settimane bloccate si annullano e la cliente non potrà più accettarlo dal suo link.',
        );

        // Se puede volver atrás sin confirmar nada.
        await tester.tap(byKey('booking-confirm'));
        await tester.pumpAndSettle();
        expect(byKey('booking-withdraw-quote-dialog'), findsOneWidget);
        await tester.tap(byKey('booking-withdraw-quote-cancel'));
        await tester.pumpAndSettle();
        expect(app.bookings.confirmations, isEmpty);

        await tester.tap(byKey('booking-confirm'));
        await tester.pumpAndSettle();
        await tester.tap(byKey('booking-withdraw-quote-confirm'));
        await tester.pumpAndSettle();

        expect(app.bookings.confirmations, hasLength(1));
        expect(byKey('booking-done'), findsOneWidget);
        expect(app.quotes.quotes['req-1']!.withdrawnAt, isNotNull);

        // Al volver, el pedido es una reserva y el presupuesto dice que se retiró.
        await tester.tap(byKey('booking-done-close'));
        await tester.pumpAndSettle();
        expect(byKey('quote-block-withdrawn'), findsOneWidget);
        expect(byKey('action-confirm-booking'), findsNothing);
      },
    );

    testWidgets('con un borrador, el aviso dice que se retira el borrador', (
      tester,
    ) async {
      await openDetail(tester, quote: buildQuote());
      await tester.tap(byKey('action-confirm-booking'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(byKey('booking-withdraws-quote')).data,
        'Questa richiesta ha una bozza di preventivo: confermando, viene ritirata e le sue settimane bloccate si annullano.',
      );
    });

    testWidgets('sin presupuesto abierto, ni aviso ni pregunta', (
      tester,
    ) async {
      final app = await openDetail(tester);
      await tester.tap(byKey('action-confirm-booking'));
      await tester.pumpAndSettle();
      expect(byKey('booking-withdraws-quote'), findsNothing);
      await tester.enterText(byKey('booking-price'), '560');
      await tester.pumpAndSettle();
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(byKey('booking-withdraw-quote-dialog'), findsNothing);
      expect(app.bookings.confirmations, hasLength(1));
    });
  });
}

// Detalle del pedido: datos completos y acciones (WhatsApp, llamada, email,
// rechazo). Verifica los links exactos que se abren. También el menú que
// eligió el cliente en la web, con la miniatura de los platos con foto.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/chosen_menu.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/photo_fakes.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

void main() {
  const restrictions = RequestRestrictions(
    allergens: [Allergen.gluten, Allergen.milk],
    diets: [Diet.vegetarian],
    note: 'niente funghi',
  );

  Future<ChefApp> openDetail(
    WidgetTester tester,
    ChefRequest request, {
    Locale deviceLocale = const Locale('it', 'IT'),
  }) => pumpChefApp(
    tester,
    requests: FakeChefRequestsRepository([request]),
    location: '/richieste/${request.id}',
    size: const Size(400, 1800),
    deviceLocales: [deviceLocale],
  );

  Future<void> tapAction(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('muestra todos los datos, incluidas las restricciones', (tester) async {
    await openDetail(tester, buildRequest(restrictions: restrictions));

    expect(find.byType(RequestDetailScreen), findsOneWidget);
    expect(find.text('Giulia Rossi'), findsWidgets);
    expect(find.text('Settimana di pasti'), findsOneWidget);
    expect(find.text('mercoledì 21 ottobre 2026'), findsOneWidget);
    expect(find.text('Mattina'), findsOneWidget);
    expect(find.text('Glutine'), findsOneWidget);
    expect(find.text('Latte e derivati'), findsOneWidget);
    expect(find.text('Vegetariana'), findsOneWidget);
    expect(find.text('niente funghi'), findsOneWidget);
    expect(find.text('Citofono: Rossi'), findsOneWidget);
    expect(find.text('+39 333 123 4567'), findsOneWidget);
    expect(find.text('giulia@example.test'), findsOneWidget);
    expect(find.text('Città Alta'), findsOneWidget);
    expect(find.text("Sì, l'ha chiesta"), findsOneWidget);
    expect(find.text('Italiano'), findsOneWidget);
    // Estimación guardada en centavos → euros.
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('detail-estimate-total'))).data,
      '78,00 €',
    );
    // Llegó a las 09:15 UTC = 11:15 en Roma.
    expect(find.text('Ricevuta il 19/10/2026 alle 11:15'), findsOneWidget);
  });

  testWidgets('pedido viejo con la compra guardada: solo el servicio, sin compra ni total', (tester) async {
    // requestRow guarda groceriesEstCents (6300), preauthCents (7245) y
    // totalCents (14100), como los pedidos de antes del 19/11/2026.
    await openDetail(tester, ChefRequest.fromJson(requestRow()));

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('detail-estimate-total'))).data,
      '78,00 €',
    );
    expect(find.text('63,00 €'), findsNothing);
    expect(find.text('72,45 €'), findsNothing);
    expect(find.text('141,00 €'), findsNothing);
    expect(
      find.text(
        'Calcolata con le tue tariffe al momento della richiesta. '
        'La spesa la fa il cliente, con la lista che gli mandi tu.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('scontrino'), findsNothing);
  });

  testWidgets('al abrirlo se marca visto', (tester) async {
    final app = await openDetail(tester, buildRequest());
    expect(app.requests.markedSeen, ['req-1']);
    expect(find.text('Vista'), findsOneWidget);
  });

  testWidgets('WhatsApp abre wa.me con el mensaje en el idioma del cliente', (
    tester,
  ) async {
    final app = await openDetail(
      tester,
      buildRequest(name: 'Lucía Fernández', phone: '+34 612 345 678', locale: ClientLocale.es),
    );

    await tapAction(tester, 'action-whatsapp');

    expect(app.launcher.launched.single.toString(),
      'https://wa.me/34612345678?text='
      'Hola%20Luc%C3%ADa%2C%20soy%20Evelyn%20de%20Radici.%20Recib%C3%AD%20tu%20'
      'solicitud%20y%20te%20escribo%20para%20organizarnos.',
    );
  });

  testWidgets('WhatsApp de un colaborador: escribe de parte de la cocinera', (
    tester,
  ) async {
    // Lo manda desde su propio teléfono: el mensaje no dice «soy Evelyn».
    final request = buildRequest(
      name: 'Lucía Fernández',
      phone: '+34 612 345 678',
      locale: ClientLocale.es,
    );
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([request]),
      accounts: FakeAccountRepository(
        chefAccountData.copyWith(chef: chefAccount.copyWith(collaborator: true)),
      ),
      location: '/richieste/${request.id}',
      size: const Size(400, 1800),
    );

    await tapAction(tester, 'action-whatsapp');

    expect(app.launcher.launched.single.toString(),
      'https://wa.me/34612345678?text='
      'Hola%20Luc%C3%ADa%2C%20te%20escribo%20de%20parte%20de%20Evelyn%20de%20'
      'Radici%3A%20recibimos%20tu%20solicitud%20y%20queremos%20organizarnos%20'
      'contigo.',
    );
  });

  testWidgets('llamar abre tel: con el número normalizado', (tester) async {
    final app = await openDetail(tester, buildRequest(phone: '333 1234567'));
    await tapAction(tester, 'action-call');
    expect(app.launcher.launched.single.toString(), 'tel:+393331234567');
  });

  testWidgets('email abre mailto: con asunto y saludo en el idioma del cliente', (
    tester,
  ) async {
    final app = await openDetail(tester, buildRequest());
    await tapAction(tester, 'action-email');
    expect(
      app.launcher.launched.single.toString(),
      'mailto:giulia@example.test'
      '?subject=La%20tua%20richiesta%20a%20Radici'
      '&body=Ciao%20Giulia%2C%0A%0A',
    );
  });

  testWidgets('teléfono no normalizable: sin WhatsApp ni llamada, con aviso', (
    tester,
  ) async {
    await openDetail(tester, buildRequest(phone: '612 345 678'));
    final whatsApp = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('action-whatsapp')),
    );
    final call = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('action-call')),
    );
    expect(whatsApp.onPressed, isNull);
    expect(call.onPressed, isNull);
    expect(find.text('Numero non valido per WhatsApp e chiamate.'), findsOneWidget);
  });

  testWidgets('si no se puede abrir el link, avisa', (tester) async {
    final app = await openDetail(tester, buildRequest());
    app.launcher.result = false;
    await tapAction(tester, 'action-call');
    expect(find.text('Impossibile aprire il link.'), findsOneWidget);
  });

  group('rechazo', () {
    testWidgets('pide confirmación y pasa a Rifiutata', (tester) async {
      final app = await openDetail(tester, buildRequest());

      await tapAction(tester, 'action-reject');
      expect(find.text('Rifiutare la richiesta di Giulia Rossi?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reject-confirm')));
      await tester.pumpAndSettle();

      expect(app.requests.rejected, ['req-1']);
      expect(find.text('Richiesta rifiutata.'), findsOneWidget);
      expect(find.text('Rifiutata'), findsOneWidget);
      expect(find.byKey(const ValueKey('action-reject')), findsNothing);
    });

    testWidgets('cancelar no rechaza', (tester) async {
      final app = await openDetail(tester, buildRequest());
      await tapAction(tester, 'action-reject');
      await tester.tap(find.byKey(const ValueKey('reject-cancel')));
      await tester.pumpAndSettle();
      expect(app.requests.rejected, isEmpty);
      expect(find.byKey(const ValueKey('action-reject')), findsOneWidget);
    });

    testWidgets('error: avisa y sigue nueva', (tester) async {
      final app = await openDetail(tester, buildRequest());
      app.requests.failReject = true;
      await tapAction(tester, 'action-reject');
      await tester.tap(find.byKey(const ValueKey('reject-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.text('Non è stato possibile rifiutare la richiesta. Riprova.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('action-reject')), findsOneWidget);
    });

    testWidgets('un pedido ya rechazado no muestra el botón', (tester) async {
      await openDetail(
        tester,
        buildRequest(status: RequestStatus.rejected, seenAt: testNow),
      );
      expect(find.byKey(const ValueKey('action-reject')), findsNothing);
    });
  });

  group('deshacer el rechazo', () {
    ChefRequest rejected() =>
        buildRequest(status: RequestStatus.rejected, seenAt: testNow);

    testWidgets('pide confirmación y vuelve a Vista', (tester) async {
      final app = await openDetail(tester, rejected());
      expect(find.text('Rifiutata'), findsOneWidget);

      await tapAction(tester, 'action-undo-reject');
      expect(find.text('Ripristinare la richiesta di Giulia Rossi?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('undo-reject-confirm')));
      await tester.pumpAndSettle();

      expect(app.requests.undoneRejects, ['req-1']);
      expect(find.text('Richiesta ripristinata: è tra le viste.'), findsOneWidget);
      expect(find.text('Vista'), findsOneWidget);
      expect(find.byKey(const ValueKey('action-undo-reject')), findsNothing);
      expect(find.byKey(const ValueKey('action-reject')), findsOneWidget);
    });

    testWidgets('cancelar no cambia nada', (tester) async {
      final app = await openDetail(tester, rejected());
      await tapAction(tester, 'action-undo-reject');
      await tester.tap(find.byKey(const ValueKey('undo-reject-cancel')));
      await tester.pumpAndSettle();
      expect(app.requests.undoneRejects, isEmpty);
      expect(find.text('Rifiutata'), findsOneWidget);
    });

    testWidgets('error: avisa y sigue rechazada', (tester) async {
      final app = await openDetail(tester, rejected());
      app.requests.failUndoReject = true;
      await tapAction(tester, 'action-undo-reject');
      await tester.tap(find.byKey(const ValueKey('undo-reject-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.text('Non è stato possibile ripristinare la richiesta. Riprova.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('action-undo-reject')), findsOneWidget);
    });

    testWidgets('rechazar por error y deshacerlo desde el mismo detalle', (
      tester,
    ) async {
      final app = await openDetail(tester, buildRequest());
      await tapAction(tester, 'action-reject');
      await tester.tap(find.byKey(const ValueKey('reject-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Rifiutata'), findsOneWidget);

      await tapAction(tester, 'action-undo-reject');
      await tester.tap(find.byKey(const ValueKey('undo-reject-confirm')));
      await tester.pumpAndSettle();
      expect(app.requests.rejected, ['req-1']);
      expect(app.requests.undoneRejects, ['req-1']);
      expect(find.text('Vista'), findsOneWidget);
    });

    testWidgets('un pedido nuevo no lo ofrece', (tester) async {
      await openDetail(tester, buildRequest());
      expect(find.byKey(const ValueKey('action-undo-reject')), findsNothing);
    });
  });

  group('marcar como cliente', () {
    testWidgets('un prospecto: aviso de los 90 días; pide confirmación y lo marca', (tester) async {
      final app = await openDetail(tester, buildRequest());
      expect(find.byKey(const ValueKey('detail-prospect-notice')), findsOneWidget);

      await tapAction(tester, 'action-mark-client');
      expect(find.text('Segnare Giulia Rossi come cliente?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mark-client-confirm')));
      await tester.pumpAndSettle();

      expect(app.requests.markedClients, [testClientId]);
      expect(find.text('Fatto: ora è tra i clienti e i suoi dati restano.'), findsOneWidget);
      expect(find.byKey(const ValueKey('action-mark-client')), findsNothing);
      expect(find.byKey(const ValueKey('detail-prospect-notice')), findsNothing);
      expect(find.byKey(const ValueKey('detail-client-kept')), findsOneWidget);
    });

    testWidgets('cancelar no cambia nada', (tester) async {
      final app = await openDetail(tester, buildRequest());
      await tapAction(tester, 'action-mark-client');
      await tester.tap(find.byKey(const ValueKey('mark-client-cancel')));
      await tester.pumpAndSettle();
      expect(app.requests.markedClients, isEmpty);
      expect(find.byKey(const ValueKey('action-mark-client')), findsOneWidget);
    });

    testWidgets('error: avisa y sigue como prospecto', (tester) async {
      final app = await openDetail(tester, buildRequest());
      app.requests.failMarkClient = true;
      await tapAction(tester, 'action-mark-client');
      await tester.tap(find.byKey(const ValueKey('mark-client-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.text('Non è stato possibile segnarlo come cliente. Riprova.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('action-mark-client')), findsOneWidget);
    });

    testWidgets('un cliente no lo ofrece', (tester) async {
      await openDetail(tester, buildRequest(clientStatus: ClientStatus.active));
      expect(find.byKey(const ValueKey('action-mark-client')), findsNothing);
      expect(find.byKey(const ValueKey('detail-prospect-notice')), findsNothing);
      expect(find.byKey(const ValueKey('detail-client-kept')), findsOneWidget);
    });
  });

  group('precio por semana', () {
    String textOf(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(ValueKey(key))).data!;

    testWidgets('4 semanas: las semanas, las fechas siguientes, el precio por semana, el total y el ahorro, sin compra', (tester) async {
      await openDetail(
        tester,
        buildRequest(
          weeks: 4,
          preferredDate: CalendarDate(2026, 11, 23),
          estimate: const RequestEstimate(
            weeks: 4,
            portions: 20,
            recipes: 3,
            cookMinutes: 180,
            autoPrice: true,
            weeklyServiceCents: 14000,
            serviceCents: 56000,
            savingsCents: 4000,
            maxPeople: 5,
          ),
        ),
      );
      expect(textOf(tester, 'detail-weeks'), '4');
      expect(find.text('Giorni a settimana'), findsOneWidget);
      expect(
        textOf(tester, 'detail-next-dates'),
        ['lun 30 nov', 'lun 7 dic', 'lun 14 dic']
            .map((date) => date.replaceAll(' ', '\u00a0'))
            .join(' · '),
      );
      expect(find.text('Servizio, 4 settimane'), findsOneWidget);
      expect(find.text('Servizio a settimana'), findsOneWidget);
      expect(textOf(tester, 'detail-estimate-total'), '560,00 €');
      expect(textOf(tester, 'detail-estimate-weekly'), '140,00 €');
      expect(textOf(tester, 'detail-estimate-savings'), '40,00 €');
      // La compra la hace el cliente: no hay fila de compra.
      expect(find.byKey(const ValueKey('detail-estimate-groceries')), findsNothing);
      // Evelyn sí ve el tiempo de cocina (es de cada sesión).
      expect(find.text('180 min'), findsOneWidget);
    });

    testWidgets('una semana: solo el precio del servicio, sin fechas siguientes ni ahorro', (tester) async {
      await openDetail(
        tester,
        buildRequest(
          estimate: const RequestEstimate(
            weeks: 1,
            portions: 20,
            autoPrice: true,
            weeklyServiceCents: 15000,
            serviceCents: 15000,
            savingsCents: 0,
          ),
        ),
      );
      expect(textOf(tester, 'detail-weeks'), '1');
      expect(find.text('Prezzo del servizio'), findsOneWidget);
      expect(textOf(tester, 'detail-estimate-total'), '150,00 €');
      expect(find.byKey(const ValueKey('detail-next-dates')), findsNothing);
      expect(find.byKey(const ValueKey('detail-estimate-weekly')), findsNothing);
      expect(find.byKey(const ValueKey('detail-estimate-savings')), findsNothing);
    });

    testWidgets('sin precio automático: más personas que el tope (con el de sus tarifas) o una sesión extra', (tester) async {
      await openDetail(
        tester,
        buildRequest(
          estimate: const RequestEstimate(
            weeks: 2,
            portions: 30,
            autoPrice: false,
            reason: NoAutoPriceReason.people,
            maxPeople: 6,
          ),
        ),
      );
      expect(
        textOf(tester, 'detail-no-auto-price'),
        'Più di 6 persone: senza prezzo automatico, prepara tu il preventivo.',
      );
      expect(find.byKey(const ValueKey('detail-estimate-total')), findsNothing);
      expect(find.byKey(const ValueKey('detail-estimate-groceries')), findsNothing);
    });

    testWidgets('sesión extra: sin semanas, días sin «a settimana» y sin compra', (tester) async {
      await openDetail(
        tester,
        buildRequest(
          type: RequestType.extra,
          estimate: const RequestEstimate(
            weeks: 1,
            portions: 16,
            autoPrice: false,
            reason: NoAutoPriceReason.extra,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('detail-weeks')), findsNothing);
      expect(find.text('Giorni'), findsOneWidget);
      expect(
        textOf(tester, 'detail-no-auto-price'),
        'Evento o sessione extra: senza prezzo automatico, prepara tu il preventivo.',
      );
      expect(find.byKey(const ValueKey('detail-estimate-groceries')), findsNothing);
    });
  });

  group('una reserva cargada a mano (pedido de la app, aceptado)', () {
    ChefRequest manual({RequestSource source = RequestSource.app}) =>
        buildRequest(
          id: 'manual-1',
          source: source,
          status: RequestStatus.accepted,
          seenAt: testNow,
          noDate: true,
          preferredSlot: null,
          estimate: null,
        );

    testWidgets('no dice «Data preferita», «Conferma su WhatsApp» ni «Nessuna stima salvata.»; las alergias, que no hay datos', (tester) async {
      await openDetail(tester, manual());
      expect(find.text('Data preferita'), findsNothing);
      expect(find.text('Senza data'), findsNothing);
      expect(find.text('Conferma su WhatsApp'), findsNothing);
      expect(find.byKey(const ValueKey('detail-no-estimate')), findsNothing);
      expect(find.text('Stima'), findsNothing);
      // Una reserva a mano no guarda alergias: el detalle lo sigue diciendo.
      expect(find.byKey(const ValueKey('detail-allergies-unknown')), findsOneWidget);
      // Lo demás sigue: el tipo y el idioma.
      expect(find.text('Settimana di pasti'), findsOneWidget);
      expect(find.text('Italiano'), findsOneWidget);
    });

    testWidgets('una reserva de la web sí los muestra (también sin estimación)', (tester) async {
      await openDetail(
        tester,
        manual(source: RequestSource.web).copyWith(
          preferredDate: CalendarDate(2026, 11, 23),
        ),
      );
      expect(find.text('Data preferita'), findsOneWidget);
      expect(find.text('lunedì 23 novembre 2026'), findsOneWidget);
      expect(find.text('Conferma su WhatsApp'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-no-estimate')), findsOneWidget);
    });
  });

  testWidgets('sin notas, sin estimación y sin fecha', (tester) async {
    await openDetail(
      tester,
      buildRequest(estimate: null, noDate: true, preferredSlot: null).copyWith(notes: null),
    );
    expect(find.text('Nessuna nota.'), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-no-estimate')), findsOneWidget);
    expect(find.text('Senza data'), findsOneWidget);
  });

  group('alergias: lo que contestó el cliente', () {
    const unknownKey = ValueKey('detail-allergies-unknown');
    const noneKey = ValueKey('detail-no-allergies');

    testWidgets('confirmó que nadie tiene: lo dice (también la celiaquía, como la casilla de la web), sin aviso de preguntar', (tester) async {
      await openDetail(tester, buildRequest(noAllergies: true));
      expect(
        tester.widget<Text>(find.byKey(noneKey)).data,
        'Ha confermato che nessuno ha allergie, intolleranze alimentari o celiachia.',
      );
      expect(find.byKey(unknownKey), findsNothing);
    });

    testWidgets('las escribió: se ven, como siempre (también varias líneas)', (tester) async {
      await openDetail(
        tester,
        buildRequest(
          restrictions: const RequestRestrictions(note: 'Marco: celiachia\nAnna: noci'),
          noAllergies: false,
        ),
      );
      expect(find.text('Marco: celiachia\nAnna: noci'), findsOneWidget);
      expect(find.byKey(noneKey), findsNothing);
      expect(find.byKey(unknownKey), findsNothing);
    });

    testWidgets('sin respuesta (pedido anterior a la pregunta): avisa que pregunte antes del menú', (tester) async {
      await openDetail(tester, buildRequest());
      expect(
        tester.widget<Text>(find.byKey(unknownKey)).data,
        'Nessun dato sulle allergie: chiedi al cliente prima di preparare il menù.',
      );
      expect(find.byKey(noneKey), findsNothing);
    });

    testWidgets(
      'solo una dieta no responde sobre alergias: el aviso, y la dieta',
      (tester) async {
        await openDetail(
          tester,
          buildRequest(
            restrictions: const RequestRestrictions(diets: [Diet.vegetarian]),
          ),
        );
        expect(find.byKey(unknownKey), findsOneWidget);
        expect(find.text('Diete'), findsOneWidget);
        expect(find.text('Vegetariana'), findsOneWidget);
        expect(find.byKey(noneKey), findsNothing);
      },
    );

    testWidgets('en español: los dos textos nuevos', (tester) async {
      await openDetail(tester, buildRequest(), deviceLocale: const Locale('es', 'ES'));
      expect(
        tester.widget<Text>(find.byKey(unknownKey)).data,
        'Sin datos de alergias: pregúntale al cliente antes de preparar el menú.',
      );
    });

    testWidgets('en español, confirmó que nadie tiene', (tester) async {
      await openDetail(tester, buildRequest(noAllergies: true), deviceLocale: const Locale('es', 'ES'));
      expect(
        tester.widget<Text>(find.byKey(noneKey)).data,
        'Confirmó que nadie tiene alergias, intolerancias alimentarias ni celiaquía.',
      );
    });
  });

  group('confirmar reserva', () {
    const action = ValueKey('action-confirm-booking');

    testWidgets('un pedido nuevo la ofrece abajo y abre la hoja', (tester) async {
      await openDetail(tester, buildRequest());
      expect(find.byKey(action), findsOneWidget);
      expect(find.text('Conferma prenotazione'), findsOneWidget);

      await tester.tap(find.byKey(action));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
    });

    testWidgets('una sesión extra también', (tester) async {
      await openDetail(tester, buildRequest(type: RequestType.extra));
      expect(find.byKey(action), findsOneWidget);
    });

    for (final status in [RequestStatus.rejected, RequestStatus.accepted, RequestStatus.quoted]) {
      testWidgets('un pedido ${status.name} no la ofrece', (tester) async {
        await openDetail(tester, buildRequest(status: status, seenAt: testNow));
        expect(find.byKey(action), findsNothing);
      });
    }

    testWidgets('un cambio de una sesión no la ofrece', (tester) async {
      await openDetail(tester, buildRequest(type: RequestType.change));
      expect(find.byKey(action), findsNothing);
    });
  });

  testWidgets('pedido inexistente', (tester) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      location: '/richieste/missing',
    );
    expect(find.byKey(const ValueKey('request-not-found')), findsOneWidget);
  });

  testWidgets('la interfaz sigue el idioma del dispositivo (inglés)', (tester) async {
    await openDetail(tester, buildRequest(), deviceLocale: const Locale('en', 'GB'));
    expect(find.text('Dietary restrictions'), findsOneWidget);
    expect(find.text('Call'), findsOneWidget);
  });

  // Pestaña «Menù» de la web (19/11/2026): hasta un plato por día, opcional.
  // Es el aviso que pidió Evelyn; ella tiene la última palabra.
  group('menú elegido por el cliente', () {
    const lasagne = MenuDish(
      id: lasagneId,
      nameIt: 'Lasagne alla bolognese',
      nameEs: 'Lasaña a la boloñesa',
      nameEn: 'Lasagne Bolognese',
    );
    const minestrone = MenuDish(id: minestroneId, nameIt: 'Minestrone di verdure', nameEs: 'Minestrone de verduras');
    const menuKey = ValueKey('detail-menu');

    Future<ChefApp> openMenu(
      WidgetTester tester, {
      List<String> wishes = const [minestroneId, lasagneId],
      int? days = 5,
      Locale deviceLocale = const Locale('it', 'IT'),
      Size size = const Size(400, 1800),
      bool failDishes = false,
    }) => pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest(wishes: wishes, days: days)])
        ..dishes.addAll({lasagneId: lasagne, minestroneId: minestrone})
        ..failDishes = failDishes,
      location: '/richieste/req-1',
      size: size,
      deviceLocales: [deviceLocale],
    );

    String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

    testWidgets('un recuadro destacado arriba, con los platos en el orden elegido', (tester) async {
      final app = await openMenu(tester);

      expect(textOf(tester, 'detail-menu-title'), 'Menù scelto dal cliente (2 di 5 giorni)');
      expect(textOf(tester, 'detail-menu-dish-0'), 'Minestrone di verdure');
      expect(textOf(tester, 'detail-menu-dish-1'), 'Lasagne alla bolognese');
      expect(
        tester.getTopLeft(find.byKey(menuKey)).dy,
        lessThan(tester.getTopLeft(find.text('Richiesta')).dy),
        reason: 'antes de los datos del pedido',
      );
      expect(app.requests.dishCalls, [
        [minestroneId, lasagneId],
      ]);
    });

    testWidgets('un plato que después se borró dice «Piatto eliminato», en su lugar', (tester) async {
      await openMenu(tester, wishes: const [risottoId, minestroneId]);
      expect(textOf(tester, 'detail-menu-title'), 'Menù scelto dal cliente (2 di 5 giorni)');
      expect(textOf(tester, 'detail-menu-dish-0'), 'Piatto eliminato');
      expect(textOf(tester, 'detail-menu-dish-1'), 'Minestrone di verdure');
    });

    testWidgets('un solo día: «1 di 1 giorno»', (tester) async {
      await openMenu(tester, wishes: const [lasagneId], days: 1);
      expect(textOf(tester, 'detail-menu-title'), 'Menù scelto dal cliente (1 di 1 giorno)');
    });

    // requests.days puede venir vacío: no se inventan los días.
    testWidgets('un pedido sin días: «(2 piatti)», sin días inventados', (tester) async {
      await openMenu(tester, days: null);
      expect(textOf(tester, 'detail-menu-title'), 'Menù scelto dal cliente (2 piatti)');
      expect(textOf(tester, 'detail-menu-dish-1'), 'Lasagne alla bolognese');
    });

    testWidgets('sin días y un solo plato: «(1 piatto)»', (tester) async {
      await openMenu(tester, wishes: const [lasagneId], days: null);
      expect(textOf(tester, 'detail-menu-title'), 'Menù scelto dal cliente (1 piatto)');
    });

    testWidgets('en español, el nombre traducido', (tester) async {
      await openMenu(tester, deviceLocale: const Locale('es', 'ES'));
      expect(textOf(tester, 'detail-menu-title'), 'Menú elegido por el cliente (2 de 5 días)');
      expect(textOf(tester, 'detail-menu-dish-0'), 'Minestrone de verduras');
      expect(textOf(tester, 'detail-menu-dish-1'), 'Lasaña a la boloñesa');
    });

    testWidgets('en inglés, el italiano si no hay traducción', (tester) async {
      await openMenu(tester, wishes: const [minestroneId, risottoId], deviceLocale: const Locale('en', 'GB'));
      expect(textOf(tester, 'detail-menu-title'), 'Menu chosen by the client (2 of 5 days)');
      expect(textOf(tester, 'detail-menu-dish-0'), 'Minestrone di verdure');
      expect(textOf(tester, 'detail-menu-dish-1'), 'Dish deleted');
    });

    testWidgets('sin platos elegidos no hay recuadro ni consulta', (tester) async {
      final app = await openMenu(tester, wishes: const []);
      expect(find.byKey(menuKey), findsNothing);
      expect(find.textContaining('Menù scelto'), findsNothing);
      expect(app.requests.dishCalls, isEmpty);
    });

    testWidgets('si no se pueden leer los nombres, el recuadro igual avisa y «Riprova» los trae', (tester) async {
      final app = await openMenu(tester, failDishes: true);
      expect(textOf(tester, 'detail-menu-title'), 'Menù scelto dal cliente (2 di 5 giorni)');
      expect(
        find.text('Impossibile caricare i piatti scelti. Controlla la connessione e riprova.'),
        findsOneWidget,
      );

      app.requests.failDishes = false;
      await tester.tap(find.byKey(const ValueKey('detail-menu-retry')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'detail-menu-dish-0'), 'Minestrone di verdure');
      expect(find.byKey(const ValueKey('detail-menu-retry')), findsNothing);
    });

    testWidgets('mientras carga los nombres, el título ya se ve', (tester) async {
      final requests = FakeChefRequestsRepository([buildRequest(wishes: const [lasagneId])])
        ..dishes[lasagneId] = lasagne
        ..pendingDishes = Completer<void>();
      final app = await pumpChefApp(tester, requests: requests, size: const Size(400, 1800));
      app.go('/richieste/req-1');
      // La barra de carga no termina nunca: sin pumpAndSettle.
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(textOf(tester, 'detail-menu-title'), 'Menù scelto dal cliente (1 di 5 giorni)');
      expect(find.byKey(const ValueKey('detail-menu-loading')), findsOneWidget);
      // El lector de pantalla dice qué carga.
      expect(
        tester.getSemantics(find.byKey(const ValueKey('detail-menu-loading'))),
        matchesSemantics(label: 'Caricamento dei piatti scelti'),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('detail-menu-title'))),
        matchesSemantics(label: 'Menù scelto dal cliente (1 di 5 giorni)', isHeader: true),
        reason: 'el encabezado es solo el título',
      );

      requests.pendingDishes!.complete();
      await tester.pumpAndSettle();
      expect(textOf(tester, 'detail-menu-dish-0'), 'Lasagne alla bolognese');
    });

    group('fotos', () {
      const photoId = 'f0000000-0000-4000-8000-0000000000aa';
      final withPhoto = minestrone.copyWith(photoId: photoId);

      Future<List<String>> openWithPhoto(
        WidgetTester tester, {
        Size size = const Size(400, 1800),
        Locale locale = const Locale('it', 'IT'),
      }) async {
        final urls = <String>[];
        await pumpChefApp(
          tester,
          requests: FakeChefRequestsRepository([buildRequest(wishes: const [minestroneId, risottoId, lasagneId])])
            ..dishes.addAll({lasagneId: lasagne, minestroneId: withPhoto}),
          location: '/richieste/req-1',
          size: size,
          deviceLocales: [locale],
          photoImage: (url) {
            urls.add(url);
            return MemoryImage(tinyJpeg);
          },
        );
        return urls;
      }

      testWidgets('un plato con foto lleva su miniatura a la derecha; los otros, como siempre', (tester) async {
        final urls = await openWithPhoto(tester);

        final photo = find.byKey(const ValueKey('detail-menu-photo-0'));
        expect(photo, findsOneWidget);
        expect(tester.getSize(photo), const Size(48, 48));
        expect(
          tester.getTopLeft(photo).dx,
          greaterThan(tester.getTopRight(find.byKey(const ValueKey('detail-menu-dish-0'))).dx),
        );
        expect(urls, ['https://fotos.test/$testChefId/$minestroneId/$photoId-thumb.jpg']);
        // El plato borrado y el que no tiene foto, sin miniatura; los nombres
        // quedan alineados.
        expect(find.byKey(const ValueKey('detail-menu-photo-1')), findsNothing);
        expect(find.byKey(const ValueKey('detail-menu-photo-2')), findsNothing);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('detail-menu-dish-0'))).dx,
          tester.getTopLeft(find.byKey(const ValueKey('detail-menu-dish-2'))).dx,
        );
      });

      for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
        testWidgets('con foto y el texto al doble, a 375×667, sin desbordes (${locale.languageCode})', (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await openWithPhoto(tester, size: const Size(375, 667), locale: locale);
          expect(tester.takeException(), isNull);
          expect(find.byKey(const ValueKey('detail-menu-photo-0')), findsOneWidget);
        });
      }
    });

    for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
      testWidgets('sin desbordes a 375×667 (${locale.languageCode})', (tester) async {
        await openMenu(
          tester,
          wishes: const [minestroneId, risottoId, lasagneId],
          size: const Size(375, 667),
          deviceLocale: locale,
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(menuKey), findsOneWidget);
      });
    }
  });
}

// Detalle del pedido: datos completos y acciones (WhatsApp, llamada, email,
// rechazo). Verifica los links exactos que se abren.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
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
      '141,00 €',
    );
    // Llegó a las 09:15 UTC = 11:15 en Roma.
    expect(find.text('Ricevuta il 19/10/2026 alle 11:15'), findsOneWidget);
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

    testWidgets('4 semanas: las semanas, las fechas siguientes, el precio por semana, el total, el ahorro y la compra', (tester) async {
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
            groceriesEstCents: 6300,
            totalCents: 81200,
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
      expect(textOf(tester, 'detail-estimate-groceries'), '63,00 €');
      expect(find.text('Spesa stimata a settimana'), findsOneWidget);
      // Evelyn sí ve el tiempo de cocina (es de cada sesión).
      expect(find.text('180 min'), findsOneWidget);
      // El total de servicio y compra (81200) no se muestra: la compra va aparte.
      expect(find.text('812,00 €'), findsNothing);
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
            groceriesEstCents: 6300,
            totalCents: 21300,
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
            groceriesEstCents: 9450,
            maxPeople: 6,
          ),
        ),
      );
      expect(
        textOf(tester, 'detail-no-auto-price'),
        'Più di 6 persone: senza prezzo automatico, prepara tu il preventivo.',
      );
      expect(find.byKey(const ValueKey('detail-estimate-total')), findsNothing);
      expect(textOf(tester, 'detail-estimate-groceries'), '94,50 €');
    });

    testWidgets('sesión extra: sin semanas, días sin «a settimana» y la compra de la sesión', (tester) async {
      await openDetail(
        tester,
        buildRequest(
          type: RequestType.extra,
          estimate: const RequestEstimate(
            weeks: 1,
            portions: 16,
            autoPrice: false,
            reason: NoAutoPriceReason.extra,
            groceriesEstCents: 5300,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('detail-weeks')), findsNothing);
      expect(find.text('Giorni'), findsOneWidget);
      expect(
        textOf(tester, 'detail-no-auto-price'),
        'Evento o sessione extra: senza prezzo automatico, prepara tu il preventivo.',
      );
      expect(find.text('Spesa stimata'), findsOneWidget);
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
}

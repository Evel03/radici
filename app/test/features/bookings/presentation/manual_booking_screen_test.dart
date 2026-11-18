// La hoja «Conferma prenotazione» a mano, en la app: para una ficha
// existente (el encabezado, «Persone e pasti» de su último pedido semanal, 4
// semanas desde mañana, el precio obligatorio, el WhatsApp en el idioma
// elegido y «Fatto», que lleva a «Prenotazioni») y para una nueva (el hogar
// compartido con el formulario, los datos que el servidor rechaza con
// «Correggi»). Con una respuesta perdida no se cierra hasta reintentar; los
// avisos del servidor; los estados antes de la hoja; y, a 375×667, la acción
// principal en el tercio inferior. "Hoy": lunes 19/10/2026, 14:00 en Roma.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/router.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/bookings/presentation/new_booking_client_screen.dart';
import 'package:radici/features/bookings/presentation/new_client_screen.dart';
import 'package:radici/features/clients/data/clients_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';

import '../../../support/browser_history.dart';
import '../../../support/chef_app.dart';
import '../../../support/client_fixtures.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/text_input_guard.dart';

/// intl separa el número del € con un espacio duro.
const String _nbsp = ' ';

void main() {
  final tomorrow = CalendarDate(2026, 10, 20);
  // Activa, con un último pedido semanal de 3 + 1, 4 días, almuerzo y cena,
  // en español.
  final chiara = buildClient(
    id: 'c-chiara',
    name: 'Chiara Rossi',
    phone: '340 111 2233',
    zone: 'Loreto',
    latestWeekly: buildLatestWeekly(
      locale: ClientLocale.es,
      adults: 3,
      kids: 1,
      days: 4,
      meals: const [Meal.lunch, Meal.dinner],
    ),
  );

  late int keys;
  setUp(() => keys = 0);

  Finder byKey(String key) => find.byKey(ValueKey(key));
  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(byKey(key)).data!;
  FilledButton confirmButton(WidgetTester tester) =>
      tester.widget<FilledButton>(byKey('booking-confirm'));

  Future<void> tapInForm(WidgetTester tester, String key) async {
    await tester.ensureVisible(byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> typePrice(WidgetTester tester, String text) async {
    await tester.ensureVisible(byKey('booking-price'));
    await tester.pumpAndSettle();
    await tester.enterText(byKey('booking-price'), text);
    await tester.pumpAndSettle();
  }

  /// La app en «Prenotazioni» → «Nuova prenotazione». Las claves de cada hoja
  /// son key-1, key-2…
  Future<ChefApp> openPicker(
    WidgetTester tester, {
    FakeClientsRepository? clients,
    FakeChefRequestsRepository? requests,
    FakeAccountRepository? accounts,
    void Function(FakeBookingsRepository bookings)? configure,
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
  }) async {
    final requestsRepository = requests ?? FakeChefRequestsRepository(const []);
    final clientsRepository = clients ?? FakeClientsRepository([chiara]);
    final bookings = FakeBookingsRepository(
      requests: requestsRepository,
      clients: clientsRepository,
    );
    configure?.call(bookings);
    final app = await pumpChefApp(
      tester,
      requests: requestsRepository,
      clients: clientsRepository,
      accounts: accounts,
      bookings: bookings,
      location: '/richieste',
      size: size,
      deviceLocales: [locale],
      overrides: [newIdProvider.overrideWithValue(() => 'key-${++keys}')],
    );
    await tester.tap(byKey('inbox-tab-bookings'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('inbox-new-booking'));
    await tester.pumpAndSettle();
    return app;
  }

  /// La hoja de Chiara, elegida en la lista.
  Future<ChefApp> openChiara(
    WidgetTester tester, {
    FakeChefRequestsRepository? requests,
    FakeAccountRepository? accounts,
    void Function(FakeBookingsRepository bookings)? configure,
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
  }) async {
    final app = await openPicker(
      tester,
      requests: requests,
      accounts: accounts,
      configure: configure,
      size: size,
      locale: locale,
    );
    await tester.tap(byKey('client-c-chiara'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmBookingScreen), findsOneWidget);
    return app;
  }

  /// La hoja de una ficha nueva: «Nuova cliente» con nombre y teléfono y
  /// «Continua».
  Future<ChefApp> openNewClient(
    WidgetTester tester, {
    void Function(FakeBookingsRepository bookings)? configure,
  }) async {
    final app = await openPicker(tester, configure: configure);
    await tester.tap(byKey('new-booking-new-client'));
    await tester.pumpAndSettle();
    await tester.enterText(byKey('new-client-name'), 'Giulia Rossi');
    await tester.enterText(byKey('new-client-phone'), '347 000 1111');
    await tester.pumpAndSettle();
    await tester.tap(byKey('new-client-continue'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmBookingScreen), findsOneWidget);
    return app;
  }

  group('una ficha existente', () {
    testWidgets('encabezado con teléfono y zona, «Persone e pasti» de su último pedido semanal, 4 semanas desde mañana y el precio vacío', (tester) async {
      await openChiara(tester);
      expect(find.widgetWithText(AppBar, 'Nuova prenotazione'), findsOneWidget);
      expect(find.text('Chiara Rossi'), findsOneWidget);
      expect(textOf(tester, 'booking-subtitle'), '340 111 2233 · Loreto');
      expect(byKey('booking-new-client-note'), findsNothing);
      expect(textOf(tester, 'booking-weeks-value'), '4');
      for (final (i, date) in [
        'mar 20 ott',
        'mar 27 ott',
        'mar 3 nov',
        'mar 10 nov',
      ].indexed) {
        expect(find.text('Settimana ${i + 1} · $date'), findsOneWidget);
      }
      await tester.ensureVisible(byKey('booking-household'));
      expect(find.text('Persone e pasti'), findsOneWidget);
      expect(textOf(tester, 'booking-adults-value'), '3');
      expect(textOf(tester, 'booking-kids-value'), '1');
      expect(textOf(tester, 'booking-days-value'), '4');
      expect(tester.widget<FilterChip>(byKey('booking-meal-lunch')).selected, isTrue);
      expect(tester.widget<FilterChip>(byKey('booking-meal-dinner')).selected, isTrue);
      await tester.ensureVisible(byKey('booking-locale-es'));
      expect(find.text('Lingua dei messaggi WhatsApp'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(byKey('booking-locale-es')).selected, isTrue);
      expect(find.text('Calcolato da persone e pasti, al massimo 300 min.'), findsOneWidget);
      // El precio, vacío y obligatorio: la barra lo dice con «Vedi».
      expect(tester.widget<TextField>(byKey('booking-price')).controller!.text, isEmpty);
      expect(textOf(tester, 'booking-blocker'), 'Manca il prezzo del servizio.');
      expect(byKey('booking-blocker-show'), findsOneWidget);
      expect(confirmButton(tester).onPressed, isNull);
      expectReadableInputs(tester);
    });

    testWidgets('con «560» el resumen; al confirmar, la pantalla final y el WhatsApp en el idioma elegido', (tester) async {
      final app = await openChiara(tester);
      await typePrice(tester, '560');
      expect(
        textOf(tester, 'booking-summary'),
        'Servizio 560,00$_nbsp€ · 140,00$_nbsp€ a settimana · arrivo 10:00',
      );
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Prenotazione confermata'), findsOneWidget);
      expect(app.bookings.confirmations.single.clientId, 'c-chiara');

      await tester.tap(byKey('booking-whatsapp'));
      await tester.pumpAndSettle();
      final whatsApp = app.launcher.launched.single;
      expect(whatsApp.path, '/393401112233');
      expect(
        whatsApp.queryParameters['text'],
        startsWith('Hola Chiara, soy Evelyn de Radici. Te confirmo las 4 sesiones'),
      );
    });

    testWidgets('confirma un colaborador: el WhatsApp, en el idioma de la clienta, escribe de parte de Evelyn', (tester) async {
      final app = await openChiara(
        tester,
        accounts: FakeAccountRepository(
          chefAccountData.copyWith(
            chef: chefAccount.copyWith(collaborator: true),
          ),
        ),
      );
      await typePrice(tester, '560');
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('booking-whatsapp'));
      await tester.pumpAndSettle();
      expect(
        app.launcher.launched.single.queryParameters['text'],
        startsWith(
          'Hola Chiara, te escribo de parte de Evelyn de Radici. Te confirmamos las 4 sesiones',
        ),
      );
    });

    testWidgets('el idioma elegido en la hoja es el del WhatsApp', (tester) async {
      final app = await openChiara(tester);
      await tapInForm(tester, 'booking-locale-en');
      await typePrice(tester, '560');
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(app.bookings.confirmations.single.locale, ClientLocale.en);
      await tester.tap(byKey('booking-whatsapp'));
      await tester.pumpAndSettle();
      expect(
        app.launcher.launched.single.queryParameters['text'],
        startsWith('Hi Chiara'),
      );
    });

    testWidgets('«Fatto» lleva a Richieste en «Prenotazioni» con la reserva nueva, también con la relectura fallando', (tester) async {
      final requests = FakeChefRequestsRepository(const []);
      final app = await openChiara(tester, requests: requests);
      await typePrice(tester, '560');
      requests.failFetch = true;
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('booking-done-close'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsNothing);
      expect(find.byType(NewBookingClientScreen), findsNothing);
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(byKey('inbox-new-booking').hitTestable(), findsOneWidget);
      expect(byKey('request-manual-request-1'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('request-manual-request-1'),
          matching: find.text('Chiara Rossi'),
        ),
        findsOneWidget,
      );
      expect(app.bookings.confirmations, hasLength(1));
    });

    testWidgets('con la bandeja en error y la red de vuelta, «Fatto» muestra la lista entera: la reserva y, en «Nuove», el pedido de la web', (tester) async {
      final requests = FakeChefRequestsRepository([
        buildRequest(
          id: 'web-new',
          name: 'Marco Bianchi',
          createdAt: DateTime.utc(2026, 10, 19, 9),
        ),
      ])..failFetch = true;
      await openChiara(tester, requests: requests);
      requests.failFetch = false;
      await typePrice(tester, '560');
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('booking-done-close'));
      await tester.pumpAndSettle();
      expect(byKey('load-error'), findsNothing);
      expect(byKey('request-manual-request-1'), findsOneWidget);
      // La barra de pestañas se desliza: «Nuove» quedó a la izquierda.
      await tester.ensureVisible(byKey('inbox-tab-new'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('inbox-tab-new'));
      await tester.pumpAndSettle();
      expect(byKey('request-web-new'), findsOneWidget);
    });

    testWidgets('después de confirmar, el atrás del sistema hace lo mismo que «Fatto»', (tester) async {
      await openChiara(tester);
      await typePrice(tester, '560');
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsNothing);
      expect(find.byType(NewBookingClientScreen), findsNothing);
      expect(byKey('request-manual-request-1'), findsOneWidget);
    });
  });

  group('una ficha nueva', () {
    testWidgets('lo dice el encabezado; confirmar y «Fatto» (el formulario no queda debajo)', (tester) async {
      final app = await openNewClient(tester);
      expect(textOf(tester, 'booking-subtitle'), '347 000 1111');
      expect(
        textOf(tester, 'booking-new-client-note'),
        'Scheda nuova: si crea quando confermi.',
      );
      await typePrice(tester, '560');
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(
        app.bookings.confirmations.single.newClient,
        const NewClientData(name: 'Giulia Rossi', phone: '+393470001111'),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(NewClientScreen), findsNothing);
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(byKey('request-manual-request-1'), findsOneWidget);
    });

    testWidgets('los adultos cambiados en la hoja vuelven al formulario; «Continua» abre otra hoja con ellos, el precio vacío y otra clave', (tester) async {
      final app = await openNewClient(tester);
      await tapInForm(tester, 'booking-adults-increment');
      expect(textOf(tester, 'booking-adults-value'), '3');
      await typePrice(tester, '100');
      await tester.tap(byKey('booking-close'));
      await tester.pumpAndSettle();
      expect(find.byType(NewClientScreen), findsOneWidget);
      expect(textOf(tester, 'new-client-adults-value'), '3');

      await tester.tap(byKey('new-client-continue'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(byKey('booking-adults-value'));
      expect(textOf(tester, 'booking-adults-value'), '3');
      expect(tester.widget<TextField>(byKey('booking-price')).controller!.text, isEmpty);
      await typePrice(tester, '200');
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(app.bookings.confirmations.single.requestKey, 'key-2');
      expect(app.bookings.confirmations.single.household?.adults, 3);
    });

    testWidgets('si el servidor no acepta los datos de la ficha nueva, lo dice y «Correggi» vuelve al formulario', (tester) async {
      await openNewClient(
        tester,
        configure: (b) => b.checksFailure = const BookingFailure(
          BookingFailureKind.invalid,
          fields: {'newClient.phone'},
        ),
      );
      expect(
        textOf(tester, 'booking-failure'),
        'Il server non accetta i dati della cliente nuova: torna indietro e controllali.',
      );
      expect(confirmButton(tester).onPressed, isNull);
      await tester.tap(byKey('booking-new-client-fix'));
      await tester.pumpAndSettle();
      expect(find.byType(NewClientScreen), findsOneWidget);
    });
  });

  testWidgets('en español: «Comprobando las fechas…» mientras corre el dryRun y, sin respuesta, «Esta pantalla queda abierta…»', (tester) async {
    final app = await openChiara(
      tester,
      locale: const Locale('es', 'ES'),
      configure: (b) => b.loseNextConfirmResponse = true,
    );
    await typePrice(tester, '560');
    // Otra cantidad de semanas vuelve a pedir el dryRun (la rueda de la barra
    // gira: sin pumpAndSettle).
    await tester.ensureVisible(byKey('booking-weeks-decrement'));
    await tester.pumpAndSettle();
    app.bookings.pendingChecks = Completer<void>();
    await tester.tap(byKey('booking-weeks-decrement'));
    await tester.pump();
    expect(textOf(tester, 'booking-checking'), 'Comprobando las fechas…');
    app.bookings.pendingChecks!.complete();
    await tester.pumpAndSettle();

    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();
    expect(
      textOf(tester, 'booking-retry-keeps-open'),
      'Esta pantalla queda abierta hasta que llegue una respuesta: así la reserva no se duplica.',
    );
  });

  testWidgets('sin respuesta al confirmar: la hoja no se cierra hasta reintentar, y el reintento no duplica', (tester) async {
    final app = await openChiara(
      tester,
      configure: (b) => b.loseNextConfirmResponse = true,
    );
    await typePrice(tester, '560');
    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();
    expect(
      textOf(tester, 'booking-retry-keeps-open'),
      'Questa pagina resta aperta finché non arriva una risposta: così la prenotazione non si duplica.',
    );
    expect(tester.widget<IconButton>(byKey('booking-close')).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmBookingScreen), findsOneWidget);

    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();
    final sent = app.bookings.confirmations;
    expect(sent, hasLength(2));
    expect(sent.last, sent.first);
    expect(app.bookings.savedByKey, hasLength(1));
    expect(
      app.requests.requests.keys.where((id) => id.startsWith('manual-request')),
      hasLength(1),
    );
    expect(byKey('booking-done-duplicate'), findsOneWidget);
  });

  testWidgets('sin respuesta tampoco al reintentar: «Chiudi comunque», con el aviso, la cierra (a 375×667, debajo de «Riprova»)', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await openChiara(
      tester,
      size: const Size(375, 667),
      configure: (b) => b.loseNextConfirmResponse = true,
    );
    await typePrice(tester, '560');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();
    expect(byKey('booking-leave-anyway'), findsNothing);

    app.bookings.confirmFailure = const BookingFailure(BookingFailureKind.unavailable);
    await tester.tap(byKey('booking-confirm'));
    await tester.pumpAndSettle();
    expect(byKey('booking-retry-keeps-open'), findsNothing);
    expect(
      textOf(tester, 'booking-retry-leave-warning'),
      'Ancora nessuna risposta. Puoi chiudere, ma la prenotazione potrebbe '
      'essere già salvata: prima di rifarla, controlla in «Prenotazioni» o in «Agenda».',
    );
    expect(
      tester.getSemantics(byKey('booking-retry-leave-warning')),
      isSemantics(isLiveRegion: true),
    );
    expect(tester.widget<IconButton>(byKey('booking-close')).onPressed, isNull);
    final retry = byKey('booking-confirm');
    final leave = byKey('booking-leave-anyway');
    expect(find.text('Chiudi comunque'), findsOneWidget);
    expect(leave.hitTestable(), findsOneWidget);
    expect(tester.getSize(leave).height, greaterThanOrEqualTo(48));
    expect(tester.getRect(leave).top, greaterThanOrEqualTo(tester.getRect(retry).bottom));
    expect(tester.getCenter(retry).dy, greaterThan(667 * 2 / 3));

    await tester.tap(leave);
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmBookingScreen), findsNothing);
    expect(find.byType(NewBookingClientScreen), findsOneWidget);
    expect(app.bookings.savedByKey, hasLength(1), reason: 'la primera quedó guardada');
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  // En /gestione/ el atrás del navegador entra por el router y no pasa por
  // PopScope: lo frena el onExit de la ruta de la hoja.
  group('el atrás del navegador', () {
    const sheet = '/richieste/nuova/prenota?cliente=c-chiara';

    testWidgets('sin respuesta al confirmar no cierra la hoja: el reintento lleva la misma clave y no duplica', (tester) async {
      final history = FakeBrowserHistory()..install(tester);
      final app = await openChiara(
        tester,
        configure: (b) => b.loseNextConfirmResponse = true,
      );
      await typePrice(tester, '560');
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(byKey('booking-retry-keeps-open'), findsOneWidget);

      final before = history.entries.last.uri;
      await history.back(tester);
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(app.container.read(routerProvider).state.uri.toString(), sheet);
      expect(history.entries.last.uri, before, reason: 'la barra vuelve a donde estaba');

      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      final sent = app.bookings.confirmations;
      expect(sent, hasLength(2));
      expect(sent.last.requestKey, 'key-1');
      expect(app.bookings.savedByKey, hasLength(1));
      expect(
        app.requests.requests.keys.where((id) => id.startsWith('manual-request')),
        hasLength(1),
      );
      expect(byKey('booking-done-duplicate'), findsOneWidget);
    });

    testWidgets('mientras se manda tampoco la cierra', (tester) async {
      final history = FakeBrowserHistory()..install(tester);
      final app = await openChiara(tester);
      await typePrice(tester, '560');
      app.bookings.pendingConfirm = Completer<void>();
      await tester.tap(byKey('booking-confirm'));
      await tester.pump();
      await history.back(tester, settle: false);
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(app.container.read(routerProvider).state.uri.toString(), sheet);

      app.bookings.pendingConfirm!.complete();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Prenotazione confermata'), findsOneWidget);
      expect(app.bookings.confirmations, hasLength(1));
    });

    testWidgets('con la hoja libre, vuelve al elegir', (tester) async {
      final history = FakeBrowserHistory()..install(tester);
      await openChiara(tester);
      await history.back(tester);
      expect(find.byType(ConfirmBookingScreen), findsNothing);
      expect(find.byType(NewBookingClientScreen), findsOneWidget);
    });

    testWidgets('si la sesión se cierra mientras espera el reintento, la lleva al login', (tester) async {
      final app = await openChiara(
        tester,
        configure: (b) => b.loseNextConfirmResponse = true,
      );
      await typePrice(tester, '560');
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(byKey('booking-retry-keeps-open'), findsOneWidget);

      app.auth.emit(null);
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsNothing);
      expect(find.byType(LoginScreen), findsOneWidget);
    });
  });

  group('lo que dice el servidor de cada semana', () {
    testWidgets('un día bloqueado es un aviso: se puede confirmar', (tester) async {
      await openChiara(
        tester,
        configure: (b) => b.statuses[tomorrow] = BookingDayStatus.blocked,
      );
      expect(textOf(tester, 'booking-week-0-status'), 'Giorno bloccato');
      await typePrice(tester, '560');
      expect(confirmButton(tester).onPressed, isNotNull);
    });

    testWidgets('un choque no deja confirmar y la barra dice qué semana', (tester) async {
      await openChiara(
        tester,
        configure: (b) => b.statuses[tomorrow] = BookingDayStatus.busy,
      );
      await typePrice(tester, '560');
      expect(confirmButton(tester).onPressed, isNull);
      expect(
        textOf(tester, 'booking-blocker'),
        "Settimana 1 · Si sovrappone a un'altra sessione: cambia quella data o l'ora.",
      );
    });

    // «Controllo le date…» se anuncia al empezar: el resultado que impide
    // confirmar también. La línea del precio no (cambia con cada tecla).
    testWidgets('el lector de pantalla oye el choque que encontró el dryRun, no la línea del precio', (tester) async {
      final semantics = tester.ensureSemantics();
      final app = await openChiara(tester);
      expect(textOf(tester, 'booking-blocker'), 'Manca il prezzo del servizio.');
      expect(
        tester.getSemantics(byKey('booking-blocker')),
        isSemantics(isLiveRegion: false),
      );
      await typePrice(tester, '560');
      // Con otra cantidad de semanas, el dryRun encuentra un choque.
      app.bookings.statuses[tomorrow] = BookingDayStatus.busy;
      await tapInForm(tester, 'booking-weeks-decrement');
      expect(
        textOf(tester, 'booking-blocker'),
        "Settimana 1 · Si sovrappone a un'altra sessione: cambia quella data o l'ora.",
      );
      expect(
        tester.getSemantics(byKey('booking-blocker')),
        isSemantics(isLiveRegion: true),
      );
      semantics.dispose();
    });
  });

  group('antes de la hoja', () {
    testWidgets('cargando la ficha: la rueda', (tester) async {
      final clients = FakeClientsRepository([chiara])
        ..pendingFetch = Completer<void>();
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        clients: clients,
      );
      app.go('/richieste/nuova/prenota?cliente=c-chiara');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(byKey('booking-loading'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Nuova prenotazione'), findsWidgets);
      clients.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Chiara Rossi'), findsOneWidget);
    });

    testWidgets('si no se pudieron leer las fichas: el mensaje y «Riprova»', (tester) async {
      final clients = FakeClientsRepository([chiara])
        ..fetchFailure = const ClientsFailure(ClientsFailureKind.unavailable);
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        clients: clients,
      );
      app.go('/richieste/nuova/prenota?cliente=c-chiara');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ConfirmBookingScreen),
          matching: find.text(
            'Impossibile caricare le schede delle clienti. Controlla la connessione e riprova.',
          ),
        ),
        findsOneWidget,
      );
      clients.fetchFailure = null;
      await tester.tap(
        find.descendant(
          of: find.byType(ConfirmBookingScreen),
          matching: byKey('load-error-retry'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chiara Rossi'), findsOneWidget);
      expect(textOf(tester, 'booking-weeks-value'), '4');
    });

    /// «Nuova prenotazione», abajo: a 375×667 en el tercio inferior, de 48 dp.
    void expectRestartBelow(WidgetTester tester) {
      final restart = byKey('booking-restart');
      expect(restart.hitTestable(), findsOneWidget);
      expect(tester.getCenter(restart).dy, greaterThan(667 * 2 / 3));
      expect(tester.getSize(restart).height, greaterThanOrEqualTo(48));
    }

    testWidgets('una ficha que no existe lo dice y propone «Nuova prenotazione», abajo', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        clients: FakeClientsRepository([chiara]),
        size: const Size(375, 667),
      );
      app.go('/richieste/nuova/prenota?cliente=nope');
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'booking-client-not-found'),
        'Questa scheda cliente non esiste più.',
      );
      expectRestartBelow(tester);
      await tester.tap(byKey('booking-restart'));
      await tester.pumpAndSettle();
      expect(find.byType(NewBookingClientScreen), findsOneWidget);
      expect(find.byType(ConfirmBookingScreen), findsNothing);
    });

    testWidgets('la hoja de una ficha nueva sin formulario (la página se recargó) lo dice y vuelve a empezar desde abajo', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        size: const Size(375, 667),
      );
      app.go('/richieste/nuova/prenota');
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'booking-new-client-missing'),
        'I dati della cliente nuova non ci sono più: ricomincia da «Nuova prenotazione».',
      );
      expectRestartBelow(tester);
      await tester.tap(byKey('booking-restart'));
      await tester.pumpAndSettle();
      expect(find.byType(NewBookingClientScreen), findsOneWidget);
      expect(find.byType(ConfirmBookingScreen), findsNothing);
    });

    testWidgets('desde un pedido que no existe, lo dice', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
      );
      app.go('/richieste/nope/prenota');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Conferma prenotazione'), findsWidgets);
      expect(
        textOf(tester, 'booking-request-not-found'),
        'Questa richiesta non esiste o non è più disponibile.',
      );
    });

    testWidgets('desde un pedido que no se pudo leer: el mensaje y «Riprova»', (tester) async {
      final requests = FakeChefRequestsRepository([
        buildRequest(seenAt: testNow, preferredDate: tomorrow),
      ])..failFetch = true;
      final app = await pumpChefApp(tester, requests: requests);
      app.go('/richieste/req-1/prenota');
      await tester.pumpAndSettle();
      final sheet = find.byType(ConfirmBookingScreen);
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(
            'Impossibile caricare le richieste. Controlla la connessione e riprova.',
          ),
        ),
        findsOneWidget,
      );
      requests.failFetch = false;
      await tester.tap(
        find.descendant(of: sheet, matching: byKey('load-error-retry')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Giulia Rossi'), findsOneWidget);
      expect(byKey('booking-confirm'), findsOneWidget);
    });
  });

  testWidgets('a 375×667 «Conferma 4 settimane» queda en el tercio inferior con el resumen arriba', (tester) async {
    await openChiara(tester, size: const Size(375, 667));
    await typePrice(tester, '560');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final confirm = byKey('booking-confirm');
    expect(confirm.hitTestable(), findsOneWidget);
    expect(find.text('Conferma 4 settimane'), findsOneWidget);
    expect(tester.getCenter(confirm).dy, greaterThan(667 * 2 / 3));
    expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
    final summary = byKey('booking-summary');
    expect(summary.hitTestable(), findsOneWidget);
    expect(tester.getRect(summary).bottom, lessThanOrEqualTo(tester.getRect(confirm).top));
    for (final key in [
      'booking-adults-increment',
      'booking-days-decrement',
      'booking-meal-lunch',
      'booking-locale-it',
    ]) {
      await tester.ensureVisible(byKey(key));
      await tester.pumpAndSettle();
      expect(tester.getSize(byKey(key)).height, greaterThanOrEqualTo(48), reason: key);
    }
    expectReadableInputs(tester);
    expect(tester.takeException(), isNull);
  });
}

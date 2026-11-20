// Hoy (/oggi), el inicio de la cocinera: al abrir la app va ahí (un enlace
// directo, como el del email, sigue abriendo su pedido) y la barra tiene 4
// destinos (el riel también). Muestra la sesión de hoy (varias, con la
// próxima primero) o la próxima: la clienta, las horas que salen de la
// sesión, las personas, las alergias resaltadas, la contaminación cruzada con
// gluten y las notas de cocina; abajo, en el tercio inferior, «Come arrivare»
// (sin dirección, «Aggiungi indirizzo») y WhatsApp (el mensaje de la ficha:
// lo firma la cocinera o, con la cuenta de un colaborador, escribe de parte
// de ella). Tocar la tarjeta abre la ficha. Los pendientes (pedidos nuevos, que
// llevan a «Nuove», y reservas que terminan, que abren su última semana), la
// tira de 7 días (que abre la Agenda en ese día), carga, error, vacío, deslizar
// para actualizar y el cambio de día a la medianoche de Roma sin reabrir.
// "Hoy": martes 17/11/2026 a las 8:00 en Roma, salvo donde se dice otra cosa.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/today/presentation/today_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';
import '../../../support/text_input_guard.dart';

void main() {
  /// Martes 17/11/2026 a las 8:00 en Roma (UTC+1).
  final morning = DateTime.utc(2026, 11, 17, 7);
  final today = CalendarDate(2026, 11, 17);

  Finder byKey(String key) => find.byKey(ValueKey(key));
  Finder card(int n) => byKey('today-session-${sessionId(n)}');
  Finder inCard(int n, Finder finder) =>
      find.descendant(of: card(n), matching: finder);
  String textOf(WidgetTester tester, String key) =>
      plainSpaces(tester.widget<Text>(byKey(key)).data!);

  CookingSession session({
    int n = 1,
    CalendarDate? date,
    int hour = 10,
    int minute = 0,
    int shopMinutes = 0,
    int cookMinutes = 180,
    SessionStatus status = SessionStatus.confirmed,
    String? requestId = bookingRequestId,
    String name = 'Giulia Rossi',
    String? phone = '+39 333 123 4567',
    String? address = 'Via Gombito 12, 24129 Bergamo',
    List<Allergen> clientAllergens = const [],
    RequestRestrictions? restrictions,
    bool? noAllergies,
  }) => buildSession(
    n: n,
    date: date ?? today,
    start: ClockTime.hm(hour, minute),
    shopMinutes: shopMinutes,
    cookMinutes: cookMinutes,
    status: status,
    requestId: requestId,
    name: name,
    phone: phone,
    address: address,
    clientAllergens: clientAllergens,
    restrictions: restrictions,
    noAllergies: noAllergies,
  );

  /// [accounts]: la cuenta con que se entra (por defecto, la de la cocinera).
  Future<ChefApp> openToday(
    WidgetTester tester, {
    List<CookingSession> sessions = const [],
    FakeSessionsRepository? repository,
    FakeChefRequestsRepository? requests,
    FakeAvailabilityRepository? availability,
    FakeAccountRepository? accounts,
    DateTime Function()? clock,
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
    bool? appleMaps = false,
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: requests ?? FakeChefRequestsRepository(const []),
      sessions: repository ?? FakeSessionsRepository(sessions),
      availability: availability,
      accounts: accounts,
      clock: clock ?? () => morning,
      size: size,
      deviceLocales: [locale],
      overrides: [
        if (appleMaps != null) appleMapsProvider.overrideWithValue(appleMaps),
      ],
    );
    expect(find.byType(TodayScreen), findsOneWidget);
    return app;
  }

  /// Desplaza Hoy hasta que [finder] se construya y se vea.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find
          .descendant(of: byKey('today'), matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
  }

  NavigationBar navBar(WidgetTester tester) =>
      tester.widget<NavigationBar>(byKey('chef-nav-bar'));

  /// Con pumpChefApp(settle: false): bombea cuadros hasta que aparece Hoy (el
  /// router primero espera la cuenta).
  Future<void> waitForToday(WidgetTester tester) async {
    for (var i = 0; i < 10 && find.byType(TodayScreen).evaluate().isEmpty; i++) {
      await tester.pump();
    }
    await tester.pump();
    expect(find.byType(TodayScreen), findsOneWidget);
  }

  group('el inicio', () {
    testWidgets('al abrir la app va a Hoy, primero de los 4 destinos de la barra', (
      tester,
    ) async {
      await openToday(tester);
      final bar = navBar(tester);
      expect(bar.destinations, hasLength(4));
      expect(bar.selectedIndex, 0);
      final labels = [
        for (final label in ['Oggi', 'Richieste', 'Agenda', 'Altro'])
          tester.getCenter(
            find.descendant(of: byKey('chef-nav-bar'), matching: find.text(label)),
          ).dx,
      ];
      expect(labels, orderedEquals([...labels]..sort()), reason: 'en ese orden');

      await tester.tap(
        find.descendant(of: byKey('chef-nav-bar'), matching: find.text('Agenda')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(navBar(tester).selectedIndex, 2);

      await tester.tap(
        find.descendant(of: byKey('chef-nav-bar'), matching: find.text('Oggi')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
    });

    testWidgets('un enlace a un pedido (el botón del email) sigue abriendo el pedido', (
      tester,
    ) async {
      await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest(id: 'req-42')]),
        location: '/richieste/req-42',
        clock: () => morning,
      );
      expect(find.byType(RequestDetailScreen), findsOneWidget);
    });

    testWidgets('pantalla ancha: el riel con los mismos 4 destinos y Hoy elegido', (
      tester,
    ) async {
      await openToday(
        tester,
        sessions: [session()],
        size: const Size(1200, 800),
      );
      final rail = tester.widget<NavigationRail>(byKey('chef-nav-rail'));
      expect(rail.destinations, hasLength(4));
      expect(rail.selectedIndex, 0);
      expect(byKey('chef-nav-bar'), findsNothing);
      expect(byKey('account-menu'), findsOneWidget);
      expect(card(1), findsOneWidget);
      expect(tester.getSize(card(1)).width, lessThanOrEqualTo(720));
      expect(tester.takeException(), isNull);
    });
  });

  group('la sesión de hoy', () {
    testWidgets(
      'la clienta, las horas de la sesión, las personas, las alergias resaltadas, la contaminación cruzada y las notas de cocina',
      (tester) async {
        await openToday(
          tester,
          sessions: [
            session(
              clientAllergens: const [Allergen.gluten],
              restrictions: const RequestRestrictions(note: 'Celiachia, noci'),
            ),
            session(n: 2, date: today.addDays(1), name: 'Marco Bianchi'),
          ],
        );

        expect(textOf(tester, 'today-date'), 'martedì 17 novembre');
        expect(card(1), findsOneWidget);
        expect(card(2), findsNothing, reason: 'la de mañana no: hoy hay una');
        expect(inCard(1, find.text('Giulia Rossi')), findsOneWidget);
        expect(
          textOf(tester, 'today-session-${sessionId(1)}-times'),
          'Arrivo 10:00 · fino alle 13:00',
        );
        expect(textOf(tester, 'today-session-${sessionId(1)}-people'), '4 persone');
        expect(inCard(1, find.text('Glutine')), findsOneWidget);
        expect(
          tester.widget<Text>(inCard(1, byKey('session-allergy-note'))).data,
          'Celiachia, noci',
        );
        expect(inCard(1, byKey('session-cross-contamination')), findsOneWidget);
        expect(
          textOf(tester, 'today-session-${sessionId(1)}-kitchen'),
          'Forno a gas',
        );
        // Nada se oculta en la ficha que no esté acá: la dirección no se muestra.
        expect(inCard(1, find.textContaining('Via Gombito')), findsNothing);
      },
    );

    testWidgets('las horas salen de lo guardado en la sesión (nada fijo), sin la compra de una de antes del 19/11/2026', (
      tester,
    ) async {
      await openToday(
        tester,
        sessions: [
          session(hour: 9, minute: 30, shopMinutes: 45, cookMinutes: 120),
        ],
      );
      expect(
        textOf(tester, 'today-session-${sessionId(1)}-times'),
        'Arrivo 09:30 · fino alle 11:30',
      );
    });

    testWidgets('sin datos de alergias, el aviso destacado de preguntar', (
      tester,
    ) async {
      await openToday(tester, sessions: [session()]);
      expect(inCard(1, byKey('session-allergies-unknown')), findsOneWidget);
      expect(inCard(1, byKey('session-cross-contamination')), findsNothing);
    });

    testWidgets('el estado, si no está confirmada', (tester) async {
      await openToday(
        tester,
        sessions: [session(status: SessionStatus.held)],
      );
      expect(
        textOf(tester, 'today-session-${sessionId(1)}-status'),
        'In attesa di conferma',
      );
    });

    testWidgets('una vieja en shopping_done, como confirmada: sin estado y, terminada, «Terminata»', (
      tester,
    ) async {
      await openToday(
        tester,
        // 14:00 en Roma: la de las 10:00 terminó a las 13:00.
        clock: () => DateTime.utc(2026, 11, 17, 13),
        sessions: [
          session(status: SessionStatus.shoppingDone),
          session(n: 2, hour: 16, status: SessionStatus.shoppingDone),
        ],
      );
      expect(textOf(tester, 'today-session-${sessionId(1)}-status'), 'Terminata');
      expect(byKey('today-session-${sessionId(2)}-status'), findsNothing);
    });

    testWidgets('«Come arrivare» abre Google Maps (Apple Maps en el iPhone) y WhatsApp, el chat', (
      tester,
    ) async {
      final app = await openToday(tester, sessions: [session()]);
      await tester.tap(byKey('today-directions'));
      await tester.pumpAndSettle();
      expect(
        app.launcher.launched.single.toString(),
        'https://www.google.com/maps/dir/?api=1&destination='
        '${Uri.encodeComponent('Via Gombito 12, 24129 Bergamo')}',
      );

      await tester.tap(byKey('today-whatsapp'));
      await tester.pumpAndSettle();
      final whatsApp = app.launcher.launched.last;
      expect(whatsApp.toString(), startsWith('https://wa.me/393331234567?text='));
      // El de la ficha: con la cuenta de la cocinera lo firma ella, con la
      // fecha y la hora de llegada, sin la dirección.
      expect(
        whatsApp.queryParameters['text'],
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'martedì 17 novembre, con arrivo alle 10:00.',
      );
    });

    testWidgets('con la cuenta de un colaborador, WhatsApp sale de su teléfono y escribe de parte de la cocinera', (
      tester,
    ) async {
      final app = await openToday(
        tester,
        sessions: [session()],
        accounts: FakeAccountRepository(
          chefAccountData.copyWith(
            chef: chefAccount.copyWith(collaborator: true),
          ),
        ),
      );
      await tester.tap(byKey('today-whatsapp'));
      await tester.pumpAndSettle();
      final whatsApp = app.launcher.launched.single;
      expect(whatsApp.toString(), startsWith('https://wa.me/393331234567?text='));
      // Ni «sono Evelyn» ni «con arrivo alle…» como si llegara él: la que
      // llega es ella («con arrivo di Evelyn alle…»).
      expect(
        whatsApp.queryParameters['text'],
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione '
        'di martedì 17 novembre, con arrivo di Evelyn alle 10:00.',
      );
    });

    testWidgets('en el iPhone, Apple Maps', (tester) async {
      final app = await openToday(
        tester,
        sessions: [session()],
        appleMaps: true,
      );
      await tester.tap(byKey('today-directions'));
      await tester.pumpAndSettle();
      expect(
        app.launcher.launched.single.toString(),
        startsWith('https://maps.apple.com/?daddr='),
      );
    });

    testWidgets('si no se puede abrir el enlace, lo avisa encima de los botones de abajo, sin taparlos', (
      tester,
    ) async {
      final app = await openToday(tester, sessions: [session()]);
      app.launcher.result = false;
      await tester.tap(byKey('today-directions'));
      await tester.pumpAndSettle();
      expect(find.text('Impossibile aprire il link.'), findsOneWidget);
      // Con el ScaffoldMessenger de la app saldría en el Scaffold de la barra
      // de navegación, sobre «Come arrivare» y WhatsApp.
      expect(
        tester.getRect(find.byType(SnackBar)).bottom,
        lessThanOrEqualTo(tester.getRect(byKey('today-actions')).top),
      );
    });

    testWidgets('sin dirección: WhatsApp es el principal y «Aggiungi indirizzo» la guarda; después, «Come arrivare»', (
      tester,
    ) async {
      final app = await openToday(
        tester,
        sessions: [session(address: null)],
      );
      expect(byKey('today-directions'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.text('WhatsApp'),
        ),
        findsOneWidget,
      );

      await tester.tap(byKey('today-add-address'));
      await tester.pumpAndSettle();
      expect(byKey('client-address-dialog'), findsOneWidget);
      expectReadableInputs(tester);
      await tester.enterText(byKey('client-address-field'), 'Via Pignolo 5, Bergamo');
      await tester.pump();
      await tester.tap(byKey('client-address-save'));
      await tester.pumpAndSettle();

      expect(app.sessions.addressUpdates.single.$2, 'Via Pignolo 5, Bergamo');
      expect(find.text('Indirizzo salvato.'), findsOneWidget);
      expect(byKey('today-directions'), findsOneWidget);
      expect(byKey('today-add-address'), findsNothing);
    });

    testWidgets('tocar la tarjeta abre la ficha; volver lleva a Hoy', (
      tester,
    ) async {
      await openToday(tester, sessions: [session()]);
      await tester.tap(card(1));
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(byKey('chef-nav-bar').hitTestable(), findsNothing);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(navBar(tester).selectedIndex, 0);
    });

    testWidgets('con el lector de pantalla, la cabecera de la tarjeta es un botón que abre la ficha y las alergias se leen aparte', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openToday(
        tester,
        sessions: [
          session(restrictions: const RequestRestrictions(note: 'Celiachia, noci')),
        ],
      );
      final header = byKey('today-session-${sessionId(1)}-header');
      expect(
        tester.getSemantics(header),
        isSemantics(isButton: true, hasTapAction: true),
      );
      expect(
        plainSpaces(tester.getSemantics(header).getSemanticsData().label),
        'Giulia Rossi, Arrivo 10:00 · fino alle 13:00, 4 persone',
      );
      expect(find.semantics.byLabel(RegExp('Celiachia, noci')), findsOneWidget);

      tester.semantics.tap(find.semantics.byLabel(RegExp(r'^Giulia Rossi, ')));
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      semantics.dispose();
    });
  });

  group('qué sesión se muestra', () {
    testWidgets('sin sesión hoy, lo dice y muestra la próxima con su día', (
      tester,
    ) async {
      await openToday(
        tester,
        sessions: [
          session(n: 3, date: today.addDays(8)),
          session(n: 2, date: today.addDays(2), name: 'Marco Bianchi'),
        ],
      );
      expect(textOf(tester, 'today-none-today'), 'Oggi non hai sessioni.');
      expect(
        textOf(tester, 'today-next-title'),
        'Prossima sessione · giovedì 19 novembre',
      );
      expect(card(2), findsOneWidget);
      expect(card(3), findsNothing);
      expect(byKey('today-directions'), findsOneWidget);
    });

    testWidgets('varias hoy: todas, la próxima primero; los botones de abajo son de esa', (
      tester,
    ) async {
      final app = await openToday(
        tester,
        // 14:00 en Roma: la de las 10:00 terminó a las 13:00.
        clock: () => DateTime.utc(2026, 11, 17, 13),
        sessions: [
          session(),
          session(
            n: 2,
            hour: 16,
            name: 'Marco Bianchi',
            phone: '+39 345 000 1111',
            address: 'Via Pignolo 5, Bergamo',
          ),
        ],
      );
      expect(card(1), findsOneWidget);
      expect(card(2), findsOneWidget);
      expect(
        tester.getTopLeft(card(2)).dy,
        lessThan(tester.getTopLeft(card(1)).dy),
      );
      // La que terminó lo dice: abajo de la próxima no parece un error.
      expect(textOf(tester, 'today-session-${sessionId(1)}-status'), 'Terminata');
      expect(byKey('today-session-${sessionId(2)}-status'), findsNothing);
      // La hora primero, con las palabras de la línea de horas de la tarjeta.
      expect(
        textOf(tester, 'today-actions-for'),
        'Arrivo 16:00 · Marco Bianchi',
      );

      await tester.tap(byKey('today-directions'));
      await tester.pumpAndSettle();
      expect(
        app.launcher.launched.single.toString(),
        contains(Uri.encodeComponent('Via Pignolo 5, Bergamo')),
      );
      await tester.tap(byKey('today-whatsapp'));
      await tester.pumpAndSettle();
      expect(
        app.launcher.launched.last.toString(),
        startsWith('https://wa.me/393450001111?text='),
      );
    });

    for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
      testWidgets('a 320×568, con un nombre largo, de quién son los botones se corta en el nombre y no en la hora (${locale.languageCode})', (
        tester,
      ) async {
        await openToday(
          tester,
          size: const Size(320, 568),
          locale: locale,
          sessions: [
            session(name: 'Maria Francesca Colombo Bertolini'),
            session(n: 2, hour: 16, name: 'Marco Bianchi'),
          ],
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          byKey('today-actions-for'),
        );
        expect(paragraph.didExceedMaxLines, isTrue, reason: 'no entra');
        final text = paragraph.text.toPlainText();
        final hourEnd = text.indexOf('10:00') + '10:00'.length;
        expect(hourEnd, greaterThan(4), reason: text);
        // La última letra que se ve, junto a los puntos suspensivos.
        final lastShown = paragraph.getPositionForOffset(
          Offset(paragraph.size.width - 1, paragraph.size.height / 2),
        );
        expect(lastShown.offset, greaterThanOrEqualTo(hourEnd), reason: text);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('con una sola sesión, los botones no repiten de quién son', (
      tester,
    ) async {
      await openToday(tester, sessions: [session()]);
      expect(byKey('today-actions'), findsOneWidget);
      expect(byKey('today-actions-for'), findsNothing);
    });

    testWidgets('las canceladas no se muestran', (tester) async {
      await openToday(
        tester,
        sessions: [
          session(status: SessionStatus.cancelled),
          session(n: 2, date: today.addDays(1)),
        ],
      );
      expect(card(1), findsNothing);
      expect(byKey('today-none-today'), findsOneWidget);
      expect(card(2), findsOneWidget);
    });

    testWidgets('sin ninguna sesión: lo dice y propone ver las solicitudes con un botón abajo, en el tercio inferior', (
      tester,
    ) async {
      await openToday(tester, size: const Size(375, 667));
      expect(
        textOf(tester, 'today-empty'),
        'Nessuna sessione in programma',
      );
      expect(byKey('today-actions'), findsNothing);
      final action = tester.getRect(byKey('today-empty-action'));
      expect(action.center.dy, greaterThan(667 * 2 / 3));
      expect(
        action.bottom,
        lessThanOrEqualTo(tester.getRect(byKey('chef-nav-bar')).top),
      );
      expect(action.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      await tester.tap(byKey('today-empty-action'));
      await tester.pumpAndSettle();
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(navBar(tester).selectedIndex, 1);
    });
  });

  group('pendientes', () {
    FakeChefRequestsRepository requests() => FakeChefRequestsRepository([
      buildRequest(id: 'nuovo-1', name: 'Marco Bianchi'),
      buildRequest(
        id: 'nuovo-2',
        name: 'Anna Verdi',
        createdAt: DateTime.utc(2026, 11, 16, 9),
      ),
      buildRequest(
        id: 'visto',
        name: 'Luca Neri',
        seenAt: DateTime.utc(2026, 11, 16, 10),
      ),
    ]);

    testWidgets('pedidos nuevos: cuántos, y un toque lleva a Richieste en «Nuove» aunque antes se haya elegido otra pestaña', (
      tester,
    ) async {
      await openToday(tester, requests: requests());
      await reveal(tester, byKey('today-new-requests'));
      // Como en el aviso de pedidos nuevos («2 nuove richieste»).
      expect(
        find.descendant(
          of: byKey('today-new-requests'),
          matching: find.text('2 nuove richieste'),
        ),
        findsOneWidget,
      );

      // En la bandeja se elige «Viste» y se vuelve a Hoy.
      await tester.tap(
        find.descendant(of: byKey('chef-nav-bar'), matching: find.text('Richieste')),
      );
      await tester.pumpAndSettle();
      await tester.tap(byKey('inbox-tab-seen'));
      await tester.pumpAndSettle();
      expect(byKey('inbox-list-seen').hitTestable(), findsOneWidget);
      await tester.tap(
        find.descendant(of: byKey('chef-nav-bar'), matching: find.text('Oggi')),
      );
      await tester.pumpAndSettle();

      await reveal(tester, byKey('today-new-requests'));
      await tester.tap(byKey('today-new-requests'));
      await tester.pumpAndSettle();
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(navBar(tester).selectedIndex, 1);
      expect(byKey('inbox-list-fresh').hitTestable(), findsOneWidget);
      expect(byKey('request-nuovo-1').hitTestable(), findsOneWidget);
      expect(byKey('request-visto').hitTestable(), findsNothing);
    });

    testWidgets('sin nada pendiente, lo dice', (tester) async {
      await openToday(tester, sessions: [session(n: 1, date: today.addDays(10))]);
      await reveal(tester, byKey('today-pending-empty'));
      expect(textOf(tester, 'today-pending-empty'), 'Niente in sospeso.');
      expect(byKey('today-new-requests'), findsNothing);
    });

    // Las reservas que terminan salen de las sesiones: sin ellas leídas, los
    // pendientes no están completos aunque la bandeja esté vacía.
    testWidgets('con la bandeja vacía, mientras cargan las sesiones no dice «Niente in sospeso»; al llegar, sí', (
      tester,
    ) async {
      final repository = FakeSessionsRepository(const [])
        ..pendingFetch = Completer<void>();
      await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        sessions: repository,
        clock: () => morning,
        settle: false,
      );
      await waitForToday(tester);
      expect(byKey('today-loading'), findsOneWidget);
      // La bandeja ya se leyó: ni su barra ni su error.
      expect(byKey('today-pending'), findsOneWidget);
      expect(byKey('today-pending-loading'), findsNothing);
      expect(byKey('today-requests-error'), findsNothing);
      expect(byKey('today-pending-empty'), findsNothing);

      repository.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(byKey('today-loading'), findsNothing);
      expect(textOf(tester, 'today-pending-empty'), 'Niente in sospeso.');
    });

    testWidgets('con la bandeja vacía y las sesiones sin leer (error), no dice «Niente in sospeso»; al leerlas con «Riprova», sí', (
      tester,
    ) async {
      final repository = FakeSessionsRepository(const [])
        ..fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
      await openToday(tester, repository: repository);
      expect(byKey('sessions-load-error'), findsOneWidget);
      expect(byKey('today-pending'), findsOneWidget);
      expect(byKey('today-pending-loading'), findsNothing);
      expect(byKey('today-requests-error'), findsNothing);
      expect(byKey('today-pending-empty'), findsNothing);

      repository.fetchFailure = null;
      await tester.tap(byKey('sessions-retry'));
      await tester.pumpAndSettle();
      expect(byKey('sessions-load-error'), findsNothing);
      expect(textOf(tester, 'today-pending-empty'), 'Niente in sospeso.');
    });

    testWidgets('reservas que terminan: un toque abre la ficha de su última semana', (
      tester,
    ) async {
      // 28/10, 4/11, 11/11 y 18/11: la última es mañana.
      await openToday(
        tester,
        sessions: buildBooking(first: CalendarDate(2026, 10, 28)),
      );
      final item = byKey('today-ending-$bookingRequestId');
      await reveal(tester, item);
      expect(
        find.descendant(
          of: item,
          matching: find.text('Finisce la prenotazione di Giulia Rossi'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: item,
          matching: findPlainText('Ultima sessione: mer 18 nov'),
        ),
        findsOneWidget,
      );

      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('session-date')).data,
        'mercoledì 18 novembre 2026',
      );
      expect(tester.widget<Text>(byKey('session-week')).data, 'Settimana 4 di 4');
    });

    testWidgets('si la bandeja no se pudo leer, lo dice con «Riprova»; mientras la vuelve a leer, la barra de carga', (
      tester,
    ) async {
      final repository = requests()..failFetch = true;
      await openToday(tester, requests: repository);
      await reveal(tester, byKey('today-requests-error'));
      expect(byKey('today-new-requests'), findsNothing);
      expect(byKey('today-pending-empty'), findsNothing);

      repository
        ..failFetch = false
        ..pendingFetch = Completer<void>();
      await tester.tap(byKey('today-requests-retry'));
      await tester.pump();
      await tester.pump();
      expect(byKey('today-pending-loading'), findsOneWidget);
      expect(byKey('today-requests-error'), findsNothing);
      expect(byKey('today-pending-empty'), findsNothing);

      repository.pendingFetch!.complete();
      await tester.pumpAndSettle();
      await reveal(tester, byKey('today-new-requests'));
      expect(byKey('today-requests-error'), findsNothing);
      expect(byKey('today-pending-loading'), findsNothing);
    });

    for (final (name, repository) in <(String, FakeChefRequestsRepository Function())>[
      ('con pendientes', requests),
      ('sin pendientes', () => FakeChefRequestsRepository(const [])),
      ('con la bandeja en error', () => requests()..failFetch = true),
    ]) {
      testWidgets('para el lector de pantalla, «Da fare» y «Prossimi 7 giorni» son encabezados sin lo de abajo adentro, y cada texto de abajo (también la pista de la tira), un nodo propio ($name)', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await openToday(tester, requests: repository());
        await reveal(tester, byKey('today-pending'));
        // En /gestione/ un encabezado con hijos sale como <header> (banner) y
        // no como encabezado.
        final header = tester.getSemantics(find.text('Da fare'));
        expect(header, isSemantics(label: 'Da fare', isHeader: true));
        expect(header.childrenCount, 0);
        final strip = tester.getSemantics(find.text('Prossimi 7 giorni'));
        expect(strip, isSemantics(label: 'Prossimi 7 giorni', isHeader: true));
        expect(strip.childrenCount, 0);
        // La pista, debajo del título de la tira: siempre está, y no se funde
        // con el encabezado ni lo lleva adentro.
        const hint = 'Tocca un giorno per aprirlo in agenda.';
        final hintNode = tester.getSemantics(find.text(hint));
        expect(hintNode, isSemantics(label: hint, isHeader: false));
        expect(hintNode.childrenCount, 0, reason: hint);
        for (final text in [
          'Niente in sospeso.',
          'Impossibile caricare le richieste.',
        ]) {
          if (find.text(text).evaluate().isEmpty) continue;
          final node = tester.getSemantics(find.text(text));
          expect(node.label, text);
          expect(node.childrenCount, 0, reason: text);
        }
        semantics.dispose();
      });
    }

    testWidgets('mientras se lee la bandeja al entrar, la barra de carga y no «Niente in sospeso»; al llegar, los pedidos nuevos', (
      tester,
    ) async {
      final repository = requests()..pendingFetch = Completer<void>();
      final app = await pumpChefApp(
        tester,
        requests: repository,
        sessions: FakeSessionsRepository(const []),
        clock: () => morning,
        settle: false,
      );
      await waitForToday(tester);
      // La bandeja ya estaba armada antes de que cargara la cuenta (el aviso
      // de pedidos nuevos la escucha desde el arranque), con la lista vacía:
      // se vuelve a leer con ese valor de antes.
      expect(
        app.container.read(chefInboxProvider),
        isA<AsyncLoading<List<ChefRequest>>>().having(
          (inbox) => inbox.hasValue,
          'con la lista vacía de antes',
          isTrue,
        ),
      );
      expect(byKey('today-pending-loading'), findsOneWidget);
      expect(byKey('today-pending-empty'), findsNothing);
      expect(byKey('today-requests-error'), findsNothing);

      repository.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(byKey('today-pending-loading'), findsNothing);
      expect(byKey('today-pending-empty'), findsNothing);
      await reveal(tester, byKey('today-new-requests'));
    });

    testWidgets('si la bandeja falla y Riverpod la reintenta, la barra de carga (ni el error ni «Niente in sospeso»); cuando deja de reintentar, el error', (
      tester,
    ) async {
      final repository = requests()..failFetch = true;
      final app = await pumpChefApp(
        tester,
        requests: repository,
        sessions: FakeSessionsRepository(const []),
        clock: () => morning,
        retry: retryOnce(),
        settle: false,
      );
      await waitForToday(tester);
      final inbox = app.container.read(chefInboxProvider);
      expect(inbox.isLoading && inbox.hasError, isTrue, reason: 'reintentando');
      expect(byKey('today-pending-loading'), findsOneWidget);
      expect(byKey('today-pending-empty'), findsNothing);
      expect(byKey('today-requests-error'), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(repository.fetchCalls, 2);
      expect(byKey('today-requests-error'), findsOneWidget);
      expect(byKey('today-pending-loading'), findsNothing);
      expect(byKey('today-pending-empty'), findsNothing);
    });
  });

  group('la tira de 7 días', () {
    testWidgets('hoy y los 6 siguientes, con sesiones, bloqueos y feriados; un toque abre la Agenda en ese día', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      // Lunes 7/12/2026: el martes 8 es la Immacolata; el miércoles 9, bloqueado.
      await openToday(
        tester,
        clock: () => DateTime.utc(2026, 12, 7, 7),
        availability: FakeAvailabilityRepository(
          blocked: [
            BlockedDay(id: 'block-1', date: CalendarDate(2026, 12, 9)),
          ],
        ),
        sessions: [session(date: CalendarDate(2026, 12, 10))],
      );
      await reveal(tester, byKey('today-strip'));

      for (var day = 7; day <= 13; day++) {
        final iso = CalendarDate(2026, 12, day).toIso();
        expect(byKey('today-strip-$iso'), findsOneWidget, reason: iso);
      }
      expect(byKey('today-strip-2026-12-14'), findsNothing);
      expect(byKey('today-strip-2026-12-08-holiday'), findsOneWidget);
      expect(byKey('today-strip-2026-12-10-sessions'), findsOneWidget);
      expect(byKey('today-strip-2026-12-11-sessions'), findsNothing);
      final blocked = tester.widget<Text>(
        find.descendant(
          of: byKey('today-strip-2026-12-09'),
          matching: find.text('9'),
        ),
      );
      expect(blocked.style?.decoration, TextDecoration.lineThrough);
      expect(
        find.bySemanticsLabel(
          RegExp(r'^martedì 8 dicembre 2026.*Festività: Immacolata Concezione'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^mercoledì 9 dicembre 2026.*bloccato')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^giovedì 10 dicembre 2026, 1 sessione')),
        findsOneWidget,
      );
      for (var day = 7; day <= 13; day++) {
        final iso = CalendarDate(2026, 12, day).toIso();
        final size = tester.getSize(byKey('today-strip-$iso'));
        expect(size.height, greaterThanOrEqualTo(48), reason: iso);
        expect(size.width, greaterThanOrEqualTo(48), reason: iso);
      }
      semantics.dispose();

      await tester.tap(byKey('today-strip-2026-12-10'));
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(navBar(tester).selectedIndex, 2);
      expect(find.text('giovedì 10 dicembre 2026'), findsOneWidget);
      expect(find.byKey(const ValueKey('agenda-title')), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('agenda-title')).data,
        'dicembre 2026',
      );
    });

    for (final (size, view) in const [
      (Size(320, 568), AgendaView.month),
      (Size(375, 667), AgendaView.month),
      (Size(375, 667), AgendaView.week),
    ]) {
      testWidgets('a ${size.width.toInt()}×${size.height.toInt()} (vista ${view.name}), tocar un día de la tira abre la Agenda con ese día a la vista: su sesión, por encima del botón flotante', (
        tester,
      ) async {
        // Lunes 7/12/2026; la sesión es el jueves 10.
        final app = await openToday(
          tester,
          size: size,
          clock: () => DateTime.utc(2026, 12, 7, 7),
          sessions: [session(date: CalendarDate(2026, 12, 10))],
        );
        app.container.read(agendaControllerProvider.notifier).setView(view);
        await reveal(tester, byKey('today-strip-2026-12-10'));
        await tester.tap(byKey('today-strip-2026-12-10'));
        await tester.pumpAndSettle();
        expect(find.byType(AgendaScreen), findsOneWidget);

        final block = byKey('session-${sessionId(1)}');
        expect(block.hitTestable(), findsOneWidget, reason: 'sin desplazar a mano');
        expect(
          tester.getRect(block).bottom,
          lessThanOrEqualTo(tester.getRect(byKey('agenda-block-range')).top),
        );
      });
    }

    // La Agenda es una rama del shell: conserva el desplazamiento. Lo que se
    // ve después de tocar un día de la tira no depende de dónde había quedado.
    for (final view in AgendaView.values) {
      for (final (away, offset, viewBuilt) in <(String, double Function(ScrollPosition, double), bool)>[
        // La vista del mes (o de la semana) ni está construida.
        ('al final de la lista, lejos del día', (agenda, _) => agenda.maxScrollExtent, false),
        // Traerla desde ahí la dejaba arriba de todo, sin lo de arriba.
        ('con la sesión del día recién pasada, arriba', (_, sessionEnd) => sessionEnd + 8, true),
      ]) {
        testWidgets('a 375×667 (vista ${view.name}), con la Agenda desplazada ($away), tocar un día de la tira la vuelve arriba y muestra el día como sin desplazar: su título y su sesión, por encima del botón flotante', (
          tester,
        ) async {
          // Lunes 7/12/2026; la sesión es el jueves 10. Con 20 pedidos sin
          // fecha, la lista sigue mucho más abajo del día.
          final app = await openToday(
            tester,
            size: const Size(375, 667),
            clock: () => DateTime.utc(2026, 12, 7, 7),
            sessions: [session(date: CalendarDate(2026, 12, 10))],
            requests: FakeChefRequestsRepository([
              for (var i = 0; i < 20; i++)
                buildRequest(id: 'senza-data-$i', noDate: true),
            ]),
          );
          app.container.read(agendaControllerProvider.notifier).setView(view);
          final title = find.text('giovedì 10 dicembre 2026');
          final block = byKey('session-${sessionId(1)}');
          ScrollPosition agenda() => tester
              .state<ScrollableState>(
                find
                    .descendant(
                      of: byKey('agenda'),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              )
              .position;
          Future<void> openDay() async {
            await reveal(tester, byKey('today-strip-2026-12-10'));
            await tester.tap(byKey('today-strip-2026-12-10'));
            await tester.pumpAndSettle();
            expect(find.byType(AgendaScreen), findsOneWidget);
          }

          // Sin desplazar: la primera vez que se abre la Agenda.
          await openDay();
          final fresh = agenda().pixels;
          expect(title.hitTestable(), findsOneWidget);
          expect(block.hitTestable(), findsOneWidget);
          final sessionEnd =
              fresh +
              tester.getRect(block).bottom -
              tester.getTopLeft(byKey('agenda')).dy;

          // Se deja la Agenda desplazada y se vuelve a Hoy.
          agenda().jumpTo(offset(agenda(), sessionEnd));
          await tester.pumpAndSettle();
          expect(block.hitTestable(), findsNothing, reason: 'fuera de la pantalla');
          expect(
            find.descendant(
              of: byKey('agenda'),
              matching: find.text('giovedì 10 dicembre 2026', skipOffstage: false),
              skipOffstage: false,
            ),
            viewBuilt ? findsOneWidget : findsNothing,
            reason: 'la vista del día, construida o no',
          );
          await tester.tap(
            find.descendant(of: byKey('chef-nav-bar'), matching: find.text('Oggi')),
          );
          await tester.pumpAndSettle();

          await openDay();
          expect(agenda().pixels, fresh);
          expect(title.hitTestable(), findsOneWidget, reason: 'el título del día');
          expect(block.hitTestable(), findsOneWidget, reason: 'sin desplazar a mano');
          expect(
            tester.getRect(block).bottom,
            lessThanOrEqualTo(tester.getRect(byKey('agenda-block-range')).top),
          );
        });
      }
    }

    testWidgets('con el lector de pantalla, un día de la tira también abre la Agenda en ese día', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openToday(
        tester,
        clock: () => DateTime.utc(2026, 12, 7, 7),
        sessions: [session(date: CalendarDate(2026, 12, 10))],
      );
      await reveal(tester, byKey('today-strip'));
      // La acción va en el nodo de la celda: en /gestione/ el clic de
      // VoiceOver solo llega a un nodo que la tiene.
      tester.semantics.tap(
        find.semantics.byLabel(RegExp(r'^giovedì 10 dicembre 2026')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(find.text('giovedì 10 dicembre 2026'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('el punto de feriado solo en un día de trabajo: Natale (viernes) sí, Santo Stefano (sábado) no', (
      tester,
    ) async {
      // Lunes 21/12/2026.
      await openToday(tester, clock: () => DateTime.utc(2026, 12, 21, 7));
      await reveal(tester, byKey('today-strip'));
      expect(byKey('today-strip-2026-12-25-holiday'), findsOneWidget);
      expect(byKey('today-strip-2026-12-26-holiday'), findsNothing);
    });

    testWidgets('resalta hoy (el primer día) y ningún otro: la cifra en negrita y el aro de color primario', (
      tester,
    ) async {
      await openToday(tester);
      await reveal(tester, byKey('today-strip'));
      Finder number(int day) => find.descendant(
        of: byKey('today-strip-2026-11-$day'),
        matching: find.text('$day'),
      );
      FontWeight? weight(int day) =>
          tester.widget<Text>(number(day)).style?.fontWeight;
      expect(weight(17), FontWeight.w700);
      for (var day = 18; day <= 23; day++) {
        expect(weight(day), isNot(FontWeight.w700), reason: '$day');
      }

      // El aro: el borde del círculo del número.
      final primary = Theme.of(
        tester.element(byKey('today-strip')),
      ).colorScheme.primary;
      bool ringed(int day) {
        final circle = find
            .ancestor(of: number(day), matching: find.byType(Container))
            .first;
        final decoration = tester.widget<Container>(circle).decoration;
        final border = decoration is BoxDecoration ? decoration.border : null;
        return border is Border && border.top.color == primary;
      }

      expect([
        for (var day = 17; day <= 23; day++)
          if (ringed(day)) day,
      ], [17]);
    });

    for (final size in const [Size(320, 568), Size(360, 800)]) {
      testWidgets('a ${size.width.toInt()}×${size.height.toInt()} va en dos filas (4 y 3) y cada día mide al menos 48×48', (
        tester,
      ) async {
        await openToday(tester, size: size);
        await reveal(tester, byKey('today-strip'));
        final cells = [
          for (var day = 17; day <= 23; day++)
            tester.getRect(byKey('today-strip-2026-11-$day')),
        ];
        for (final (i, cell) in cells.indexed) {
          expect(cell.width, greaterThanOrEqualTo(48), reason: '${17 + i}');
          expect(cell.height, greaterThanOrEqualTo(48), reason: '${17 + i}');
        }
        expect({for (final cell in cells.take(4)) cell.top}, hasLength(1));
        expect({for (final cell in cells.skip(4)) cell.top}, hasLength(1));
        expect(cells[4].top, greaterThanOrEqualTo(cells[0].bottom));
        expect(cells[4].width, cells[0].width, reason: 'el mismo ancho');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a 375 entra en una fila de 7, cada uno de al menos 48 de ancho', (
      tester,
    ) async {
      await openToday(tester, size: const Size(375, 667));
      await reveal(tester, byKey('today-strip'));
      final cells = [
        for (var day = 17; day <= 23; day++)
          tester.getRect(byKey('today-strip-2026-11-$day')),
      ];
      expect({for (final cell in cells) cell.top}, hasLength(1));
      for (final cell in cells) {
        expect(cell.width, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('el lector de pantalla dice cuál es hoy', (tester) async {
      final semantics = tester.ensureSemantics();
      await openToday(tester);
      await reveal(tester, byKey('today-strip'));
      expect(
        find.bySemanticsLabel(RegExp(r'^Oggi, martedì 17 novembre 2026')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'^Oggi, mercoledì')), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp(r'^mercoledì 18 novembre 2026')),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('con la letra al doble, el día y el número de cada celda crecen como mucho una vez y media (entran en su círculo)', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await openToday(tester, size: const Size(375, 667));
      await reveal(tester, byKey('today-strip'));
      for (final text in ['17', 'mar']) {
        final scaler = MediaQuery.textScalerOf(
          tester.element(
            find.descendant(
              of: byKey('today-strip-2026-11-17'),
              matching: find.text(text),
            ),
          ),
        );
        expect(scaler.scale(10), 15, reason: text);
      }
    });

    testWidgets('si la disponibilidad no se pudo leer, el aviso queda separado del borde de la tarjeta', (
      tester,
    ) async {
      await openToday(
        tester,
        availability: FakeAvailabilityRepository()..failFetch = true,
      );
      await reveal(tester, byKey('today-strip'));
      final message = find.descendant(
        of: byKey('today-strip'),
        matching: find.text('Impossibile caricare i giorni bloccati.'),
      );
      expect(
        tester.getTopLeft(message).dx - tester.getTopLeft(byKey('today-strip')).dx,
        greaterThanOrEqualTo(12),
      );
    });

    testWidgets('un punto por sesión: dos sesiones el mismo día, dos puntos', (
      tester,
    ) async {
      await openToday(
        tester,
        sessions: [session(), session(n: 2, hour: 15, name: 'Marco Bianchi')],
      );
      await reveal(tester, byKey('today-strip'));
      expect(
        find.descendant(
          of: byKey('today-strip-2026-11-17-sessions'),
          matching: find.byType(Container),
        ),
        findsNWidgets(2),
      );
    });
  });

  group('carga, error y actualizar', () {
    testWidgets('mientras cargan las sesiones, la rueda en su lugar (los pedidos nuevos y la tira ya se ven); después, la sesión', (
      tester,
    ) async {
      final repository = FakeSessionsRepository([session()])
        ..pendingFetch = Completer<void>();
      await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest(id: 'nuovo-1')]),
        sessions: repository,
        clock: () => morning,
        settle: false,
      );
      await waitForToday(tester);
      expect(byKey('today-loading'), findsOneWidget);
      expect(byKey('today-actions'), findsNothing);
      expect(byKey('today-new-requests'), findsOneWidget);
      expect(byKey('today-strip'), findsOneWidget);
      // Sin las sesiones no se sabe qué reservas terminan.
      expect(byKey('today-pending-empty'), findsNothing);

      repository.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(byKey('today-loading'), findsNothing);
      expect(card(1), findsOneWidget);
    });

    testWidgets('si la primera lectura de sesiones falla y Riverpod la reintenta, la rueda (no el error); si el reintento sale bien, la sesión', (
      tester,
    ) async {
      final repository = FakeSessionsRepository([session()])
        ..fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
      await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        sessions: repository,
        clock: () => morning,
        retry: retryOnce(),
        settle: false,
      );
      await waitForToday(tester);
      expect(byKey('today-loading'), findsOneWidget);
      expect(byKey('sessions-load-error'), findsNothing);

      repository.fetchFailure = null;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(byKey('today-loading'), findsNothing);
      expect(card(1), findsOneWidget);
    });

    testWidgets('si no se pudieron leer las sesiones, el aviso con «Riprova» en lugar de la tarjeta (los pedidos nuevos y la tira siguen); mientras vuelve a leer, la rueda', (
      tester,
    ) async {
      final repository = FakeSessionsRepository([session()])
        ..fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
      await openToday(
        tester,
        repository: repository,
        requests: FakeChefRequestsRepository([buildRequest(id: 'nuovo-1')]),
      );
      expect(
        find.descendant(
          of: byKey('sessions-load-error'),
          matching: find.text('Impossibile caricare le sessioni.'),
        ),
        findsOneWidget,
      );
      expect(byKey('load-error'), findsNothing, reason: 'no a pantalla completa');
      expect(byKey('today-actions'), findsNothing);
      expect(byKey('today-empty'), findsNothing);
      expect(byKey('today-new-requests'), findsOneWidget);
      expect(byKey('today-strip'), findsOneWidget);
      // Sin las sesiones no se sabe qué reservas terminan.
      expect(byKey('today-pending-empty'), findsNothing);

      repository
        ..fetchFailure = null
        ..pendingFetch = Completer<void>();
      await tester.tap(byKey('sessions-retry'));
      await tester.pump();
      await tester.pump();
      expect(byKey('today-loading'), findsOneWidget);
      expect(byKey('sessions-load-error'), findsNothing);

      repository.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(card(1), findsOneWidget);
      expect(byKey('today-actions'), findsOneWidget);
    });

    testWidgets('«Ricarica», arriba, vuelve a leer la bandeja, la disponibilidad y las sesiones sin deslizar; mientras lee no se vuelve a tocar y, si falla, lo avisa', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final app = await openToday(tester);
      expect(byKey('today-empty'), findsOneWidget);
      // Deslizar es un gesto: VoiceOver y el mouse de /gestione/ no lo hacen.
      final reload = byKey('chef-reload');
      expect(
        tester.getSemantics(reload),
        isSemantics(tooltip: 'Ricarica', isButton: true, hasTapAction: true),
      );
      final fetches = (
        sessions: app.sessions.fetchCalls,
        requests: app.requests.fetchCalls,
        availability: app.availability.fetchCalls,
      );

      app.sessions
        ..sessions[sessionId(1)] = session()
        ..pendingFetch = Completer<void>();
      await tester.tap(reload);
      await tester.pump();
      expect(tester.widget<IconButton>(reload).onPressed, isNull);
      app.sessions.pendingFetch!.complete();
      app.sessions.pendingFetch = null;
      await tester.pumpAndSettle();
      expect(card(1), findsOneWidget);
      expect(app.sessions.fetchCalls, fetches.sessions + 1);
      expect(app.requests.fetchCalls, fetches.requests + 1);
      expect(app.availability.fetchCalls, fetches.availability + 1);
      expect(tester.widget<IconButton>(reload).onPressed, isNotNull);

      app.sessions.fetchFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      await tester.tap(reload);
      await tester.pumpAndSettle();
      expect(
        find.text('Aggiornamento non riuscito. Controlla la connessione.'),
        findsOneWidget,
      );
      expect(card(1), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('si una relectura falla con las sesiones ya leídas, quedan la tarjeta y los botones, con el aviso y «Riprova»', (
      tester,
    ) async {
      final app = await openToday(tester, sessions: [session()]);
      app.sessions.fetchFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      // Lo que pasa con «Riprova» o al elegir en la Agenda un mes anterior:
      // la lectura se vuelve a armar.
      app.container.invalidate(sessionsControllerProvider);
      await tester.pumpAndSettle();
      expect(card(1), findsOneWidget);
      expect(byKey('today-actions'), findsOneWidget);
      expect(byKey('sessions-load-error'), findsOneWidget);
      expect(byKey('load-error'), findsNothing);

      app.sessions.fetchFailure = null;
      await tester.tap(byKey('sessions-retry'));
      await tester.pumpAndSettle();
      expect(byKey('sessions-load-error'), findsNothing);
      expect(card(1), findsOneWidget);
    });

    testWidgets('deslizar para actualizar trae lo nuevo; si falla, lo avisa y queda lo que había', (
      tester,
    ) async {
      final app = await openToday(tester);
      expect(byKey('today-empty'), findsOneWidget);
      final fetches = app.sessions.fetchCalls;
      final requestFetches = app.requests.fetchCalls;
      final availabilityFetches = app.availability.fetchCalls;

      app.sessions.sessions[sessionId(1)] = session();
      await tester.fling(byKey('today'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(card(1), findsOneWidget);
      expect(app.sessions.fetchCalls, fetches + 1);
      expect(app.requests.fetchCalls, requestFetches + 1);
      expect(app.availability.fetchCalls, availabilityFetches + 1);

      app.sessions.fetchFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      await tester.fling(byKey('today'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(
        find.text('Aggiornamento non riuscito. Controlla la connessione.'),
        findsOneWidget,
      );
      expect(card(1), findsOneWidget);
    });
  });

  group('sin reabrir la app', () {
    testWidgets('a la medianoche de Roma pasa al día nuevo, también la tira', (
      tester,
    ) async {
      // 23:59:30 del martes 17/11 en Roma.
      var now = DateTime.utc(2026, 11, 17, 22, 59, 30);
      await openToday(
        tester,
        clock: () => now,
        sessions: [session(date: CalendarDate(2026, 11, 18))],
      );
      expect(textOf(tester, 'today-date'), 'martedì 17 novembre');
      expect(byKey('today-next-title'), findsOneWidget);
      expect(card(1), findsOneWidget);

      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'today-date'), 'mercoledì 18 novembre');
      expect(byKey('today-next-title'), findsNothing);
      expect(byKey('today-none-today'), findsNothing);
      expect(card(1), findsOneWidget);
      await reveal(tester, byKey('today-strip'));
      expect(byKey('today-strip-2026-11-17'), findsNothing);
      expect(byKey('today-strip-2026-11-18'), findsOneWidget);
      expect(byKey('today-strip-2026-11-24'), findsOneWidget);
    });

    testWidgets('a las 23:30 UTC de invierno ya es el día siguiente en Roma', (
      tester,
    ) async {
      await openToday(
        tester,
        clock: () => DateTime.utc(2026, 11, 17, 23, 30),
        sessions: [
          session(hour: 20),
          session(n: 2, date: CalendarDate(2026, 11, 18)),
        ],
      );
      expect(textOf(tester, 'today-date'), 'mercoledì 18 novembre');
      expect(card(2), findsOneWidget);
      expect(card(1), findsNothing);
      expect(byKey('today-none-today'), findsNothing);
    });
  });

  group('teléfono', () {
    for (final size in const [Size(375, 667), Size(400, 900)]) {
      testWidgets(
        'a ${size.width.toInt()}×${size.height.toInt()}, «Come arrivare» y WhatsApp abajo, en el tercio inferior, con 48 dp',
        (tester) async {
          await openToday(
            tester,
            size: size,
            sessions: [
              session(
                clientAllergens: const [Allergen.gluten, Allergen.milk],
                restrictions: const RequestRestrictions(
                  note: 'Niente funghi, il bambino è celiaco',
                ),
              ),
            ],
          );
          final bar = tester.getRect(byKey('chef-nav-bar'));
          for (final key in ['today-directions', 'today-whatsapp']) {
            final rect = tester.getRect(byKey(key));
            expect(rect.center.dy, greaterThan(size.height * 2 / 3), reason: key);
            expect(rect.bottom, lessThanOrEqualTo(bar.top), reason: key);
            expect(rect.height, greaterThanOrEqualTo(48), reason: key);
          }
        },
      );
    }

    for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
      testWidgets('a 375×667 sin desbordes (${locale.languageCode})', (
        tester,
      ) async {
        await openToday(
          tester,
          size: const Size(375, 667),
          locale: locale,
          requests: FakeChefRequestsRepository([
            buildRequest(id: 'nuovo-1'),
            buildRequest(id: 'nuovo-2'),
          ]),
          availability: FakeAvailabilityRepository(
            blocked: [BlockedDay(id: 'block-1', date: today.addDays(3))],
          ),
          sessions: [
            ...buildBooking(
              first: CalendarDate(2026, 10, 27),
              clientAllergens: const [Allergen.gluten, Allergen.milk],
              restrictions: const RequestRestrictions(
                diets: [Diet.vegetarian],
                note: 'Niente funghi, il bambino è celiaco, e niente frutta a guscio',
              ),
            ),
          ],
        );
        expect(tester.takeException(), isNull);
        for (final key in ['today-directions', 'today-whatsapp']) {
          expect(tester.getSize(byKey(key)).height, greaterThanOrEqualTo(48));
        }
        await reveal(tester, byKey('today-strip'));
        expect(tester.takeException(), isNull);
        for (final key in ['today-new-requests', 'today-ending-$bookingRequestId']) {
          expect(
            tester.getSize(byKey(key)).height,
            greaterThanOrEqualTo(48),
            reason: key,
          );
        }
        await tester.drag(byKey('today'), const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'a 375×667 sin dirección: los botones de 48 dp y el diálogo sin desbordes (${locale.languageCode})',
        (tester) async {
          await openToday(
            tester,
            size: const Size(375, 667),
            locale: locale,
            sessions: [
              session(address: null, restrictions: webRestrictions),
              session(n: 2, hour: 15, address: null, name: 'Marco Bianchi'),
            ],
          );
          for (final key in ['today-whatsapp', 'today-add-address']) {
            final rect = tester.getRect(byKey(key));
            expect(rect.height, greaterThanOrEqualTo(48), reason: key);
            expect(rect.center.dy, greaterThan(667 * 2 / 3), reason: key);
          }
          expect(tester.takeException(), isNull);
          await tester.tap(byKey('today-add-address'));
          await tester.pumpAndSettle();
          expectReadableInputs(tester);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}

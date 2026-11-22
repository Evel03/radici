// El presupuesto de punta a punta en la app (SPEC 5.8): «Prepara il
// preventivo» con la hoja de la reserva (el precio de todo el presupuesto,
// con su reparto exacto) y, al crearlo, el menú de la semana 1 con el aviso
// de que sale junto con el presupuesto; al volver, el pedido muestra el
// borrador. Si la primera llegada pasa con la hoja abierta, no lo crea y lo
// dice (también al lector de pantalla). El menú de otra semana del
// presupuesto no se manda todavía. La vista previa traduce cada error del
// presupuesto con el paso que sigue. Y la bandeja dice qué pedidos tienen el
// presupuesto mandado, rechazado o vencido.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/presentation/menu_send_screen.dart';
import 'package:radici/features/week_menu/presentation/week_menu_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/menu_send_fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/quote_fixtures.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      plainSpaces(tester.widget<Text>(byKey(key)).data!);

  VoidCallback? onPressedOf(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(byKey(key)).onPressed;

  Future<void> tapVisible(WidgetTester tester, String key) async {
    await tester.ensureVisible(byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(byKey(key));
    await tester.pumpAndSettle();
  }

  final monday = CalendarDate(2026, 11, 23);

  testWidgets(
    'preparar: el precio de todo el presupuesto con su reparto; al crearlo, el menú de la semana 1 con el aviso, y al volver, el borrador',
    (tester) async {
      final requests = FakeChefRequestsRepository([
        buildRequest(
          weeks: 3,
          preferredDate: monday,
          estimate: null,
          seenAt: testNow,
        ),
      ]);
      final sessions = FakeSessionsRepository();
      final app = await pumpChefApp(
        tester,
        requests: requests,
        sessions: sessions,
        recipes: FakeRecipesRepository(sampleRecipes()),
        location: '/richieste/req-1',
        size: const Size(400, 1000),
      );

      await tester.tap(byKey('action-prepare-quote'));
      await tester.pumpAndSettle();
      // Sin precio automático: lo escribe Evelyn, y ve cuánto va en cada semana.
      await tester.enterText(byKey('booking-price'), '500');
      await tester.pumpAndSettle();
      expect(
        findPlainText('Per settimana: 166,67 € · 166,67 € · 166,66 €'),
        findsOneWidget,
      );
      expect(splitServiceCents(50000, 3), [16667, 16667, 16666]);

      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();

      // Creado: sus semanas quedaron retenidas y se abrió el menú de la semana 1.
      final created = app.quotes.creations.single;
      expect(created.serviceTotalCents, 50000);
      expect(created.dates, weeklyDates(monday, 3));
      expect(find.byType(WeekMenuScreen), findsOneWidget);
      expect(byKey('week-menu-quote-first'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: byKey('week-menu-quote-first'),
                matching: find.byType(Text),
              ),
            )
            .data,
        'Il menù della settimana 1 parte insieme al preventivo: salvalo e tocca «Invia» per mandare alla cliente entrambe le cose.',
      );
      expect(sessions.sessions.values.map((s) => s.status).toSet(), {
        SessionStatus.held,
      });

      // Al volver, el pedido muestra el borrador (la hoja ya no está).
      await tester.tap(byKey('week-menu-back'));
      await tester.pumpAndSettle();
      expect(find.byType(RequestDetailScreen), findsOneWidget);
      expect(byKey('quote-block-draft'), findsOneWidget);
      expect(textOf(tester, 'quote-total'), '500,00 €');
      expect(
        textOf(tester, 'quote-week-quote-1-3-detail'),
        'Arrivo 10:00 · 166,66 €',
      );
    },
  );

  testWidgets(
    'si la primera llegada pasa con la hoja abierta, «Crea il preventivo» no lo crea: la semana y la barra dicen por qué, y el lector de pantalla lo oye',
    (tester) async {
      final semantics = tester.ensureSemantics();
      // Ahora: lunes 19/10 a las 14:00. El pedido prefiere el martes 20/10.
      var now = testNow;
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([
          buildRequest(
            weeks: 2,
            preferredDate: CalendarDate(2026, 10, 20),
            estimate: null,
            seenAt: testNow,
          ),
        ]),
        location: '/richieste/req-1',
        size: const Size(400, 1000),
        clock: () => now,
      );
      await tester.tap(byKey('action-prepare-quote'));
      await tester.pumpAndSettle();
      await tester.enterText(byKey('booking-price'), '280');
      await tester.pumpAndSettle();
      // El martes a las 10:00 (la sugerida): se puede crear.
      expect(onPressedOf(tester, 'booking-confirm'), isNotNull);

      // La hoja quedó abierta hasta el martes a las 10:30.
      now = DateTime.utc(2026, 10, 20, 8, 30);
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();

      expect(app.quotes.creations, isEmpty);
      const arrivalPassed =
          "L'arrivo è già passato: la cliente accetta il preventivo prima "
          "dell'arrivo. Scegli una data futura.";
      expect(textOf(tester, 'booking-week-0-status'), arrivalPassed);
      expect(textOf(tester, 'booking-blocker'), 'Settimana 1 · $arrivalPassed');
      // El botón queda gris sin que nada más cambie a la vista: la línea de
      // la barra se anuncia.
      expect(
        tester.getSemantics(byKey('booking-blocker')),
        isSemantics(isLiveRegion: true),
      );
      expect(onPressedOf(tester, 'booking-confirm'), isNull);
      semantics.dispose();
    },
  );

  group('el menú de otra semana del presupuesto', () {
    Future<ChefApp> openWeek(WidgetTester tester, int week) {
      final weeks = quoteSessions();
      return pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        sessions: FakeSessionsRepository([
          for (final w in weeks)
            buildSession(
              id: w.id,
              date: w.date,
              status: SessionStatus.held,
              requestStatus: RequestStatus.quoted,
            ),
        ]),
        recipes: FakeRecipesRepository(sampleRecipes()),
        menus: FakeSessionMenusRepository(
          menus: {quoteSessionId(week): savedLasagneMenu()},
          statuses: {quoteSessionId(week): SessionStatus.held},
        ),
        location: '/sessioni/${quoteSessionId(week)}/menu',
        deviceLocales: const [Locale('es')],
      );
    }

    testWidgets('la semana 2 lo dice y «Mandar» queda deshabilitado', (
      tester,
    ) async {
      await openWeek(tester, 2);
      expect(byKey('week-menu-quote-later'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: byKey('week-menu-quote-later'),
                matching: find.byType(Text),
              ),
            )
            .data,
        'Semana del presupuesto: su menú se manda cuando la clienta lo acepte (antes sale solo el de la semana 1).',
      );
      expect(onPressedOf(tester, 'week-menu-send'), isNull);
    });

    testWidgets('la semana 1 se manda (con el presupuesto)', (tester) async {
      await openWeek(tester, 1);
      expect(byKey('week-menu-quote-first'), findsOneWidget);
      expect(onPressedOf(tester, 'week-menu-send'), isNotNull);
    });
  });

  group('los errores del presupuesto en la vista previa', () {
    Future<ChefApp> openPreview(
      WidgetTester tester, {
      List<MenuSendFailure> previewFailures = const [],
      List<MenuSendFailure> sendFailures = const [],
    }) async {
      final menus = FakeSessionMenusRepository(
        menus: {quoteSessionId(1): savedLasagneMenu(version: 2)},
        statuses: {quoteSessionId(1): SessionStatus.held},
      );
      final sends = FakeMenuSendsRepository(menus: menus)
        ..previewFailures.addAll(previewFailures)
        ..sendFailures.addAll(sendFailures)
        ..previewQuotes[quoteSessionId(1)] = testPreviewQuote;
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        sessions: FakeSessionsRepository([
          for (final w in quoteSessions())
            buildSession(
              id: w.id,
              date: w.date,
              status: SessionStatus.held,
              requestStatus: RequestStatus.quoted,
            ),
        ]),
        recipes: FakeRecipesRepository(sampleRecipes()),
        menus: menus,
        menuSends: sends,
        location: '/sessioni/${quoteSessionId(1)}/menu',
        deviceLocales: const [Locale('es')],
      );
      await tester.tap(byKey('week-menu-send'));
      await tester.pumpAndSettle();
      expect(find.byType(MenuSendScreen), findsOneWidget);
      return app;
    }

    testWidgets('cerrado: lo dice, sin otra vista previa', (tester) async {
      await openPreview(
        tester,
        previewFailures: const [
          MenuSendFailure(MenuSendFailureKind.quoteClosed),
        ],
      );
      expect(
        textOf(tester, 'menu-send-preview-error'),
        'El presupuesto ya no está abierto (se aceptó, se rechazó, se retiró o venció): este menú ya no sale con él.',
      );
      expect(byKey('menu-send-preview-again'), findsNothing);
      expect(byKey('menu-send-retry-preview'), findsNothing);
      expect(byKey('menu-send-failed-close'), findsOneWidget);
    });

    testWidgets('otra semana: lo dice', (tester) async {
      await openPreview(
        tester,
        previewFailures: const [
          MenuSendFailure(MenuSendFailureKind.quoteWeekNotFirst),
        ],
      );
      expect(
        textOf(tester, 'menu-send-preview-error'),
        'Esta semana se manda cuando la clienta acepte el presupuesto: antes sale solo el menú de la semana 1.',
      );
    });

    testWidgets(
      'cambió mientras se armaba: otra vista previa, con el presupuesto de ahora',
      (tester) async {
        final app = await openPreview(
          tester,
          previewFailures: const [
            MenuSendFailure(MenuSendFailureKind.quoteChanged),
          ],
        );
        expect(
          textOf(tester, 'menu-send-preview-error'),
          'El presupuesto cambió (otro precio, una semana movida o cancelada): arma otra vista previa.',
        );
        await tester.tap(byKey('menu-send-preview-again'));
        await tester.pumpAndSettle();
        expect(app.menuSends.previews, hasLength(2));
        expect(byKey('menu-send-quote'), findsOneWidget);
      },
    );

    testWidgets('cambió desde la vista previa: no salió nada y ofrece otra', (
      tester,
    ) async {
      final app = await openPreview(
        tester,
        sendFailures: const [MenuSendFailure(MenuSendFailureKind.quoteChanged)],
      );
      expect(byKey('menu-send-quote'), findsOneWidget);
      await tester.tap(byKey('menu-send-submit'));
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'menu-send-error'),
        'Desde la vista previa cambió el presupuesto (otro precio, una semana movida o cancelada): no salió nada. Arma otra vista previa.',
      );
      expect(byKey('menu-send-retry'), findsNothing);
      await tapVisible(tester, 'menu-send-new-preview');
      expect(app.menuSends.previews, hasLength(2));
    });

    testWidgets(
      'el email salió pero el presupuesto cambió: lo dice y no reintenta el mismo envío',
      (tester) async {
        await openPreview(
          tester,
          sendFailures: const [
            MenuSendFailure(MenuSendFailureKind.quoteChanged, emailSent: true),
          ],
        );
        await tester.tap(byKey('menu-send-submit'));
        await tester.pumpAndSettle();
        expect(byKey('menu-send-retry'), findsNothing);
        expect(byKey('menu-send-new-preview'), findsOneWidget);
      },
    );
  });

  testWidgets(
    'la bandeja dice qué pedidos tienen el presupuesto mandado, rechazado o vencido',
    (tester) async {
      await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([
          buildRequest(
            id: 'r-quoted',
            status: RequestStatus.quoted,
            seenAt: testNow,
          ),
          buildRequest(
            id: 'r-declined',
            status: RequestStatus.declined,
            seenAt: testNow,
          ),
          buildRequest(
            id: 'r-expired',
            status: RequestStatus.expired,
            seenAt: testNow,
          ),
          buildRequest(id: 'r-seen', seenAt: testNow),
        ]),
        location: '/richieste',
        size: const Size(400, 1200),
      );
      await tester.tap(byKey('inbox-tab-seen'));
      await tester.pumpAndSettle();

      expect(textOf(tester, 'request-r-quoted-status'), 'Preventivo inviato');
      expect(
        textOf(tester, 'request-r-declined-status'),
        'Rifiutata dal cliente',
      );
      expect(textOf(tester, 'request-r-expired-status'), 'Scaduta');
      expect(byKey('request-r-seen-status'), findsNothing);
    },
  );
}

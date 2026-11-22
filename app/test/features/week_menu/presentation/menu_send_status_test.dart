// El estado del envío del menú donde se muestra un menú: la ficha de la
// sesión, el editor y las semanas de la reserva (con una sola lectura para
// todas). Sin mandar; mandado el día y la hora y por dónde; confirmado por la
// clienta; cambios pedidos, con su mensaje entero, en varios renglones y
// seleccionable; y el menú que cambió después de mandarlo (también al
// guardar en el editor). Si no se puede leer, lo dice con «Reintentar».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/menu_send_fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      plainSpaces(tester.widget<Text>(byKey(key)).data!);

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  final session = sessionId(2);

  /// La clienta contestó el lunes 23/11 a las 10:15 de Roma.
  final answeredAt = DateTime.utc(2026, 11, 23, 9, 15);

  /// La semana 2 con su menú guardado ([savedVersion]) y sus envíos [sent].
  Future<ChefApp> open(
    WidgetTester tester, {
    required String location,
    int savedVersion = 2,
    List<MenuSendRecord> sent = const [],
    List<CookingSession>? booking,
    Map<String, int> otherSaved = const {},
    FakeChefRequestsRepository? requests,
  }) async {
    final menus = FakeSessionMenusRepository(
      menus: {
        session: savedLasagneMenu(version: savedVersion),
        for (final MapEntry(:key, :value) in otherSaved.entries)
          key: savedLasagneMenu(version: value),
      },
    );
    return pumpChefApp(
      tester,
      requests: requests ?? FakeChefRequestsRepository(const []),
      sessions: FakeSessionsRepository(booking ?? buildBooking()),
      recipes: FakeRecipesRepository(sampleRecipes()),
      menus: menus,
      menuSends: FakeMenuSendsRepository(menus: menus, sent: sent),
      location: location,
      deviceLocales: const [Locale('es')],
    );
  }

  group('la ficha', () {
    testWidgets(
      'confirmado por la clienta, con cuándo y por dónde había salido',
      (tester) async {
        await open(
          tester,
          location: '/sessioni/$session',
          sent: [
            sentMenu(
              sessionId: session,
              menuVersion: 2,
              confirmedAt: answeredAt,
            ),
          ],
        );
        expect(find.byType(CookingSessionScreen), findsOneWidget);
        await tester.ensureVisible(byKey('session-menu-status'));
        expect(
          textOf(tester, 'session-menu-status-confirmed'),
          'La clienta lo confirmó el 23/11 a las 10:15.',
        );
        expect(
          textOf(tester, 'session-menu-status-sent-on'),
          'Mandado el 22/11 a las 14:32 por email.',
        );
        expect(byKey('session-menu-status-changed-since'), findsNothing);
      },
    );

    testWidgets(
      'cambios pedidos: el mensaje de la clienta entero, en varios renglones y seleccionable',
      (tester) async {
        const message =
            'Sin cebolla, por favor.\nY una sopa más para el jueves.';
        await open(
          tester,
          location: '/sessioni/$session',
          sent: [
            sentMenu(
              sessionId: session,
              menuVersion: 2,
              via: const [MenuSendChannel.whatsapp],
              changesRequestedAt: answeredAt,
              changesText: message,
            ),
          ],
        );
        await tester.ensureVisible(byKey('session-menu-status'));
        expect(
          textOf(tester, 'session-menu-status-changes'),
          'La clienta pidió cambios el 23/11 a las 10:15:',
        );
        expect(
          tester
              .widget<SelectableText>(byKey('session-menu-status-changes-text'))
              .data,
          message,
        );
        expect(
          textOf(tester, 'session-menu-status-sent-on'),
          'Mandado el 22/11 a las 14:32 por WhatsApp.',
        );
      },
    );

    testWidgets(
      'el menú cambió después de mandarlo: lo dice, y el botón es «Mandar de nuevo»',
      (tester) async {
        await open(
          tester,
          location: '/sessioni/$session',
          savedVersion: 3,
          sent: [sentMenu(sessionId: session, menuVersion: 2)],
        );
        await tester.ensureVisible(byKey('session-menu-status'));
        expect(
          textOf(tester, 'session-menu-status-changed-since'),
          'El menú cambió después de mandarlo: la clienta tiene el de antes. Mándalo de nuevo.',
        );
        expect(
          find.descendant(
            of: byKey('session-menu-send'),
            matching: find.text('Mandar de nuevo'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('si no se puede leer el envío, lo dice con «Reintentar»', (
      tester,
    ) async {
      final app = await open(tester, location: '/sessioni/$session');
      app.menuSends.readFailure = const MenuSendFailure(
        MenuSendFailureKind.unavailable,
      );
      // Deslizar para actualizar vuelve a leer el envío (la clienta puede
      // haber contestado).
      await tester.fling(byKey('session-detail'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      await tester.ensureVisible(byKey('session-menu-status-error'));
      expect(
        textOf(tester, 'session-menu-status-error'),
        'No se pudo saber si el menú se mandó.',
      );
      app.menuSends.readFailure = null;
      await tapVisible(tester, byKey('session-menu-status-retry'));
      expect(
        textOf(tester, 'session-menu-status-not-sent'),
        'Todavía no se mandó a la clienta.',
      );
    });
  });

  testWidgets(
    'el editor: el estado arriba y, al guardar un cambio después de mandarlo, dice que cambió',
    (tester) async {
      await open(
        tester,
        location: '/sessioni/$session/menu',
        sent: [sentMenu(sessionId: session, menuVersion: 2)],
      );
      expect(
        textOf(tester, 'week-menu-status-sent'),
        'Mandado el 22/11 a las 14:32 por email.',
      );
      expect(byKey('week-menu-status-changed-since'), findsNothing);

      await tapVisible(tester, byKey('week-menu-dish-more-$lasagneId'));
      await tapVisible(tester, byKey('week-menu-save'));
      await tester.ensureVisible(byKey('week-menu-status'));
      expect(
        textOf(tester, 'week-menu-status-changed-since'),
        'El menú cambió después de mandarlo: la clienta tiene el de antes. Mándalo de nuevo.',
      );
    },
  );

  testWidgets(
    'las semanas de la reserva: el estado de cada una (cambios pedidos con el mensaje entero), con una sola lectura para todas',
    (tester) async {
      final request = buildRequest(
        id: bookingRequestId,
        status: RequestStatus.accepted,
        weeks: 4,
        seenAt: testNow,
      );
      final app = await open(
        tester,
        location: '/richieste/$bookingRequestId',
        requests: FakeChefRequestsRepository([request]),
        otherSaved: {sessionId(1): 1, sessionId(3): 1},
        sent: [
          sentMenu(
            id: 'send-a',
            sessionId: sessionId(1),
            changesRequestedAt: answeredAt,
            changesText: 'Más verduras.\nSin picante.',
          ),
          sentMenu(id: 'send-b', sessionId: session, menuVersion: 2),
        ],
      );
      await tester.ensureVisible(byKey('booking-menus'));
      final first = 'booking-menu-status-${sessionId(1)}';
      await tester.ensureVisible(byKey(first));
      expect(
        textOf(tester, '$first-changes'),
        'La clienta pidió cambios el 23/11 a las 10:15:',
      );
      expect(
        tester.widget<SelectableText>(byKey('$first-changes-text')).data,
        'Más verduras.\nSin picante.',
      );
      expect(
        textOf(tester, 'booking-menu-status-$session-sent'),
        'Mandado el 22/11 a las 14:32 por email.',
      );
      expect(
        textOf(tester, 'booking-menu-status-${sessionId(3)}-not-sent'),
        'Todavía no se mandó a la clienta.',
      );
      // Sin menú guardado ni envío, el renglón ya lo dice.
      expect(byKey('booking-menu-status-${sessionId(4)}'), findsNothing);
      expect(app.menuSends.latestCalls.single, [
        sessionId(1),
        session,
        sessionId(3),
        sessionId(4),
      ]);
    },
  );

  testWidgets(
    'una sesión sin pedido no tiene estado ni «Mandar a la clienta»',
    (tester) async {
      await open(
        tester,
        location: '/sessioni/${sessionId(9)}',
        booking: [buildSession(n: 9, requestId: null)],
      );
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(byKey('session-menu-status'), findsNothing);
      expect(byKey('session-menu-send'), findsNothing);
      expect(SessionStatus.confirmed.name, 'confirmed');
    },
  );
}

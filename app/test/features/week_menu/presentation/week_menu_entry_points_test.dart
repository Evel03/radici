// Por dónde se llega al menú de una semana: el bloque «Menú de la semana» de
// la ficha de la sesión (sin menú, con menú, en una cocinada o cobrada, en una
// cancelada; vuelve a contar después de guardar), las semanas de la reserva en
// el detalle del pedido aceptado y «Armar el menú de la semana 1» después de
// confirmar la reserva.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/router.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/features/week_menu/presentation/week_menu_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(byKey(key)).data!;

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// La ficha de la semana [n] de una reserva de 4, en español.
  Future<ChefApp> openSession(
    WidgetTester tester, {
    int n = 2,
    List<CookingSession>? booking,
    Map<String, SavedWeekMenu> saved = const {},
    FakeSessionMenusRepository? menus,
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      sessions: FakeSessionsRepository(booking ?? buildBooking()),
      recipes: FakeRecipesRepository(sampleRecipes()),
      menus: menus ?? FakeSessionMenusRepository(menus: saved),
      location: '/sessioni/${sessionId(n)}',
      deviceLocales: const [Locale('es')],
    );
    expect(find.byType(CookingSessionScreen), findsOneWidget);
    return app;
  }

  group('el bloque de la ficha', () {
    testWidgets(
      'sin menú: lo dice y «Armar el menú» abre el editor de esa semana',
      (tester) async {
        await openSession(tester);
        await tester.ensureVisible(byKey('session-menu'));
        expect(find.text('Menú de la semana'), findsOneWidget);
        expect(
          textOf(tester, 'session-menu-summary'),
          'Todavía no tiene menú.',
        );
        expect(find.text('Armar el menú'), findsOneWidget);
        await tapVisible(tester, byKey('session-menu-open'));
        expect(find.byType(WeekMenuScreen), findsOneWidget);
        expect(textOf(tester, 'week-menu-week'), 'Semana 2 de 4');
      },
    );

    testWidgets(
      'con menú: cuántos platos y renglones, «Editar el menú»; al volver de guardar, cuenta lo nuevo',
      (tester) async {
        await openSession(tester, saved: {sessionId(2): savedLasagneMenu()});
        await tester.ensureVisible(byKey('session-menu'));
        expect(
          textOf(tester, 'session-menu-summary'),
          '1 plato · 3 en la lista de compras',
        );
        expect(find.text('Editar el menú'), findsOneWidget);

        await tapVisible(tester, byKey('session-menu-open'));
        await tapVisible(tester, find.byTooltip('Quitar Sale'));
        await tapVisible(tester, byKey('week-menu-save'));
        await tester.tap(byKey('week-menu-back'));
        await tester.pumpAndSettle();
        expect(find.byType(CookingSessionScreen), findsOneWidget);
        expect(
          textOf(tester, 'session-menu-summary'),
          '1 plato · 2 en la lista de compras',
        );
      },
    );

    testWidgets('si no se puede leer, lo dice con «Reintentar»', (
      tester,
    ) async {
      final menus = FakeSessionMenusRepository()
        ..summaryFailure = const MenuFailure(MenuFailureKind.unavailable);
      await openSession(tester, menus: menus);
      await tester.ensureVisible(byKey('session-menu-error'));
      expect(
        textOf(tester, 'session-menu-error'),
        'No se pudo cargar el menú. Revisa la conexión y vuelve a intentarlo.',
      );
      menus.summaryFailure = null;
      await tapVisible(tester, byKey('session-menu-retry'));
      expect(textOf(tester, 'session-menu-summary'), 'Todavía no tiene menú.');
    });

    testWidgets(
      'una cocinada muestra su menú sin botón; sin menú, ni el bloque',
      (tester) async {
        await openSession(
          tester,
          booking: buildBooking(
            statuses: const {2: SessionStatus.cooked, 3: SessionStatus.paid},
          ),
          saved: {sessionId(2): savedLasagneMenu()},
        );
        await tester.ensureVisible(byKey('session-menu'));
        expect(
          textOf(tester, 'session-menu-summary'),
          '1 plato · 3 en la lista de compras',
        );
        expect(byKey('session-menu-open'), findsNothing);
      },
    );

    testWidgets('una cocinada sin menú y una cancelada no tienen el bloque', (
      tester,
    ) async {
      final app = await openSession(
        tester,
        booking: buildBooking(
          statuses: const {2: SessionStatus.paid, 3: SessionStatus.cancelled},
        ),
      );
      expect(byKey('session-menu'), findsNothing);
      app.go('/sessioni/${sessionId(3)}');
      await tester.pumpAndSettle();
      expect(byKey('session-menu'), findsNothing);
    });
  });

  testWidgets(
    'el detalle de una reserva lista sus semanas vivas con el menú de cada una; tocar una abre su menú',
    (tester) async {
      final booking = buildBooking(
        statuses: const {3: SessionStatus.cancelled},
      );
      final request = buildRequest(
        id: bookingRequestId,
        status: RequestStatus.accepted,
        weeks: 4,
        seenAt: testNow,
      );
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([request]),
        sessions: FakeSessionsRepository(booking),
        recipes: FakeRecipesRepository(sampleRecipes()),
        menus: FakeSessionMenusRepository(
          menus: {sessionId(1): savedLasagneMenu()},
        ),
        location: '/richieste/$bookingRequestId',
        deviceLocales: const [Locale('es')],
      );
      await tester.ensureVisible(byKey('booking-menus'));
      expect(find.text('Menús de las semanas'), findsOneWidget);
      // La 3 está cancelada: quedan 3 semanas.
      expect(byKey('booking-menu-${sessionId(3)}'), findsNothing);
      expect(find.textContaining('Semana 1 ·'), findsOneWidget);
      expect(find.textContaining('Semana 3 ·'), findsOneWidget);
      expect(find.textContaining('Semana 4 ·'), findsNothing);
      expect(
        textOf(tester, 'booking-menu-summary-${sessionId(1)}'),
        '1 plato · 3 en la lista de compras',
      );
      expect(
        textOf(tester, 'booking-menu-summary-${sessionId(2)}'),
        'Todavía no tiene menú.',
      );
      expect(app.menus.summaryCalls.single, [
        sessionId(1),
        sessionId(2),
        sessionId(4),
      ]);

      await tapVisible(tester, byKey('booking-menu-${sessionId(2)}'));
      expect(find.byType(WeekMenuScreen), findsOneWidget);
      expect(textOf(tester, 'week-menu-week'), 'Semana 2 de 3');
      // Se apila solo el menú: al volver, el pedido.
      await tester.tap(byKey('week-menu-back'));
      await tester.pumpAndSettle();
      expect(byKey('booking-menus'), findsOneWidget);
    },
  );

  testWidgets(
    'después de confirmar la reserva, «Armar el menú de la semana 1» abre el menú de la primera semana',
    (tester) async {
      final monday = CalendarDate(2026, 11, 23);
      final requests = FakeChefRequestsRepository([
        buildRequest(
          weeks: 4,
          preferredDate: monday,
          estimate: fourWeeksEstimate,
          seenAt: testNow,
        ),
      ]);
      final app = await pumpChefApp(
        tester,
        requests: requests,
        bookings: FakeBookingsRepository(requests: requests),
        location: '/richieste/req-1',
        deviceLocales: const [Locale('es')],
      );
      await tester.tap(byKey('action-confirm-booking'));
      await tester.pumpAndSettle();
      await tester.enterText(byKey('booking-price'), '560');
      await tester.pumpAndSettle();
      await tester.tap(byKey('booking-confirm'));
      await tester.pumpAndSettle();
      expect(byKey('booking-done'), findsOneWidget);
      expect(find.text('Armar el menú de la semana 1'), findsOneWidget);

      await tapVisible(tester, byKey('booking-done-menu'));
      // La sesión de la primera semana que devolvió el servidor.
      expect(
        tester.widget<WeekMenuScreen>(find.byType(WeekMenuScreen)).sessionId,
        'session-1',
      );
      final router = app.container.read(routerProvider);
      // Se apila sobre la hoja: al volver, la reserva confirmada sigue ahí.
      await tester.tap(find.byType(BackButtonIcon).last);
      await tester.pumpAndSettle();
      expect(byKey('booking-done'), findsOneWidget);
      expect(router.canPop(), isTrue);
    },
  );
}

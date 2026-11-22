// «Menús para mandar» en Hoy: las semanas de los próximos 7 días que esperan
// algo con su menú, cada una con la clienta, «Semana k de N», el día y la
// llegada, su estado y el límite (48 h antes de la llegada, hora de Roma),
// resaltado si faltan menos de 24 h o ya pasó; tocar una abre su menú y,
// después de mandarlo, ya no está. Sin ninguna, la sección no sale; si no se
// puede leer, lo dice con «Reintentar».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/today/presentation/today_screen.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/features/week_menu/presentation/menu_send_screen.dart';
import 'package:radici/features/week_menu/presentation/week_menu_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/menu_send_fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  /// Domingo 22/11/2026 a las 10:30 en Roma (UTC+1).
  final now = DateTime.utc(2026, 11, 22, 9, 30);

  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      plainSpaces(tester.widget<Text>(byKey(key)).data!);

  /// El texto de una etiqueta (la de su clave tiene un Text adentro).
  String pillText(WidgetTester tester, String key) => plainSpaces(
    tester
        .widget<Text>(
          find.descendant(of: byKey(key), matching: find.byType(Text)),
        )
        .data!,
  );

  Future<ChefApp> openToday(
    WidgetTester tester, {
    required List<CookingSession> sessions,
    FakeSessionMenusRepository? menus,
    FakeMenuSendsRepository? menuSends,
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      sessions: FakeSessionsRepository(sessions),
      recipes: FakeRecipesRepository(sampleRecipes()),
      menus: menus,
      menuSends: menuSends,
      clock: () => now,
      deviceLocales: const [Locale('es')],
    );
    expect(find.byType(TodayScreen), findsOneWidget);
    return app;
  }

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

  testWidgets(
    'cada semana con la clienta, «Semana k de N», el día y la llegada, su estado y el límite; resaltado si faltan menos de 24 h o ya pasó',
    (tester) async {
      await openToday(
        tester,
        sessions: [
          // La 8 de 8 de una reserva que empezó en octubre: el miércoles 25.
          ...buildBooking(weeks: 8, first: CalendarDate(2026, 10, 7)),
          // El lunes 23: el límite (el sábado 21) ya pasó.
          buildSession(
            n: 21,
            date: CalendarDate(2026, 11, 23),
            requestId: 'b0000000-0000-4000-8000-0000000000c1',
            name: 'Marta Bianchi',
          ),
          // El viernes 27 a las 11:00: el límite es el miércoles 25.
          buildSession(
            n: 22,
            date: CalendarDate(2026, 11, 27),
            start: const ClockTime.hm(11, 0),
            requestId: 'b0000000-0000-4000-8000-0000000000c2',
            name: 'Laura Neri',
          ),
        ],
      );
      await reveal(tester, byKey('today-menus'));
      expect(textOf(tester, 'today-menus-title'), 'Menús para mandar');

      final first = sessionId(21);
      final booking = sessionId(8);
      final later = sessionId(22);
      // Por fecha.
      final order = [
        for (final id in [first, booking, later])
          tester.getTopLeft(byKey('today-menu-$id')).dy,
      ];
      expect(order, orderedEquals([...order]..sort()));

      expect(
        textOf(tester, 'today-menu-when-$booking'),
        'Semana 8 de 8 · mié 25 de nov · llega 10:00',
      );
      expect(
        find.descendant(
          of: byKey('today-menu-$booking'),
          matching: find.text('Giulia Rossi'),
        ),
        findsOneWidget,
      );
      expect(pillText(tester, 'today-menu-state-$booking'), 'Sin menú');
      expect(
        pillText(tester, 'today-menu-deadline-$booking'),
        'Límite: lun 23 de nov, 10:00',
      );
      // Faltan menos de 24 h: el ícono de aviso.
      expect(
        find.descendant(
          of: byKey('today-menu-deadline-$booking'),
          matching: find.byIcon(Icons.warning_amber_rounded),
        ),
        findsOneWidget,
      );

      // Una reserva de una semana no dice «Semana 1 de 1».
      expect(
        textOf(tester, 'today-menu-when-$first'),
        'lun 23 de nov · llega 10:00',
      );
      expect(
        pillText(tester, 'today-menu-deadline-$first'),
        'Límite vencido: sáb 21 de nov, 10:00',
      );

      expect(
        pillText(tester, 'today-menu-deadline-$later'),
        'Límite: mié 25 de nov, 11:00',
      );
      expect(
        find.descendant(
          of: byKey('today-menu-deadline-$later'),
          matching: find.byIcon(Icons.schedule),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tocar una abre su menú; después de mandarlo, al volver ya no está',
    (tester) async {
      final menus = FakeSessionMenusRepository(
        menus: {sessionId(8): savedLasagneMenu(version: 2)},
      );
      final app = await openToday(
        tester,
        sessions: buildBooking(weeks: 8, first: CalendarDate(2026, 10, 7)),
        menus: menus,
      );
      final tile = byKey('today-menu-${sessionId(8)}');
      await reveal(tester, tile);
      expect(
        pillText(tester, 'today-menu-state-${sessionId(8)}'),
        'Armado, sin mandar',
      );

      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(
        tester.widget<WeekMenuScreen>(find.byType(WeekMenuScreen)).sessionId,
        sessionId(8),
      );

      await tester.tap(byKey('week-menu-send'));
      await tester.pumpAndSettle();
      expect(find.byType(MenuSendScreen), findsOneWidget);
      await tester.tap(byKey('menu-send-submit'));
      await tester.pumpAndSettle();
      expect(byKey('menu-send-sent'), findsOneWidget);
      expect(app.menuSends.sent.single.sessionId, sessionId(8));
      await tester.tap(byKey('menu-send-done'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('week-menu-back'));
      await tester.pumpAndSettle();

      expect(find.byType(TodayScreen), findsOneWidget);
      expect(byKey('today-menus'), findsNothing);
    },
  );

  testWidgets('sin semanas que esperen algo, la sección no sale', (
    tester,
  ) async {
    final menus = FakeSessionMenusRepository(
      menus: {sessionId(8): savedLasagneMenu(version: 2)},
    );
    await openToday(
      tester,
      sessions: buildBooking(weeks: 8, first: CalendarDate(2026, 10, 7)),
      menus: menus,
      menuSends: FakeMenuSendsRepository(
        menus: menus,
        sent: [sentMenu(sessionId: sessionId(8), menuVersion: 2)],
      ),
    );
    expect(byKey('today-menus'), findsNothing);
    expect(byKey('today-menus-title'), findsNothing);
  });

  testWidgets('si no se pueden leer los envíos, lo dice con «Reintentar»', (
    tester,
  ) async {
    final menus = FakeSessionMenusRepository();
    final sends = FakeMenuSendsRepository(menus: menus)
      ..readFailure = const MenuSendFailure(MenuSendFailureKind.unavailable);
    await openToday(
      tester,
      sessions: buildBooking(weeks: 8, first: CalendarDate(2026, 10, 7)),
      menus: menus,
      menuSends: sends,
    );
    await reveal(tester, byKey('today-menus-error'));
    expect(
      textOf(tester, 'today-menus-error'),
      'No se pudo saber qué menús faltan mandar.',
    );
    sends.readFailure = null;
    await tester.tap(byKey('today-menus-retry'));
    await tester.pumpAndSettle();
    expect(byKey('today-menu-${sessionId(8)}'), findsOneWidget);
    expect(const WeekMenuSummary().dishes, 0);
  });
}

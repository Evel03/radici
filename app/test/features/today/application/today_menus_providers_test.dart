// «Menús para mandar» de Hoy sin widgets: las semanas de los próximos 7 días
// (día de Roma) que esperan algo con su menú, leídas con una consulta de cada
// cosa para todas (los menús, los últimos envíos y las semanas vivas de sus
// reservas: nunca una por semana), con «Semana k de N» de la reserva entera
// aunque empiece antes de lo que lee la agenda y el límite de 48 h antes de
// la llegada. La hora solo descarta y resalta (no vuelve a leer); guardar,
// mandar y «Ricarica» sí. Si una lectura falla, el error, sin reintentar
// solo.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/today/application/today_menus_providers.dart';
import 'package:radici/features/today/application/today_providers.dart';
import 'package:radici/features/today/domain/pending_menus.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/menu_send_fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  /// Domingo 22/11/2026 a las 10:30 en Roma (UTC+1).
  var now = DateTime.utc(2026, 11, 22, 9, 30);

  /// Una reserva de 8 semanas que empezó el 7/10: la 8 es el miércoles 25/11
  /// (la agenda lee desde el 1/11, así que la mitad no la tiene).
  List<CookingSession> longBooking() =>
      buildBooking(weeks: 8, first: CalendarDate(2026, 10, 7));

  late FakeSessionsRepository sessions;
  late FakeSessionMenusRepository menus;
  late FakeMenuSendsRepository sends;
  late ProviderContainer container;

  Future<void> start(List<CookingSession> booking) async {
    sessions = FakeSessionsRepository(booking);
    sends = FakeMenuSendsRepository(menus: menus);
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: chefUser),
        ),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        sessionsRepositoryProvider.overrideWithValue(sessions),
        sessionMenusRepositoryProvider.overrideWithValue(menus),
        menuSendsRepositoryProvider.overrideWithValue(sends),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    container.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
    // Como Hoy, que lo escucha.
    container.listen(todayPendingMenusProvider, (_, _) {});
    await pumpEventQueue();
  }

  List<PendingMenu> pending() =>
      container.read(todayPendingMenusProvider).requireValue;

  setUp(() {
    now = DateTime.utc(2026, 11, 22, 9, 30);
    menus = FakeSessionMenusRepository();
  });

  test('la semana sin menú de los próximos días, con «Semana k de N» de la reserva entera y el límite de 48 h', () async {
    await start(longBooking());

    final menu = pending().single;
    expect(menu.session.id, sessionId(8));
    expect(menu.state, PendingMenuState.noMenu);
    expect(menu.position, (week: 8, weeks: 8));
    // Miércoles 25/11 a las 10:00 de Roma: el lunes 23 a las 10:00. Faltan
    // menos de 24 h: se resalta.
    expect(menu.deadline, DateTime.utc(2026, 11, 23, 9));
    expect(menu.deadlinePassed(now), isFalse);
    expect(menu.deadlineNear(now), isTrue);
    expect(menus.summaryCalls, [
      [sessionId(8)],
    ]);
    expect(sends.latestCalls, [
      [sessionId(8)],
    ]);
    expect(sessions.bookingWeeksCalls, [
      [bookingRequestId],
    ]);
  });

  test('una consulta de cada cosa para todas las semanas y reservas (sin una por semana)', () async {
    const otherRequest = 'b0000000-0000-4000-8000-0000000000bb';
    await start([
      ...buildBooking(weeks: 2, first: CalendarDate(2026, 11, 23)),
      ...buildBooking(
        weeks: 2,
        first: CalendarDate(2026, 11, 24),
        firstN: 11,
        requestId: otherRequest,
      ),
    ]);
    expect(
      [for (final m in pending()) m.session.id],
      [sessionId(1), sessionId(11)],
    );
    expect(menus.summaryCalls.single, [sessionId(1), sessionId(11)]);
    expect(sends.latestCalls.single, [sessionId(1), sessionId(11)]);
    expect(
      sessions.bookingWeeksCalls.single,
      unorderedEquals([bookingRequestId, otherRequest]),
    );
    expect(pending().first.position, (week: 1, weeks: 2));
  });

  test('qué falta: armado sin mandar, cambios pedidos, cambiado después; lo mandado sin cambios no está', () async {
    menus = FakeSessionMenusRepository(
      menus: {
        sessionId(1): savedLasagneMenu(version: 1),
        sessionId(2): savedLasagneMenu(version: 2),
        sessionId(3): savedLasagneMenu(version: 2),
        sessionId(4): savedLasagneMenu(version: 3),
      },
    );
    await start([
      for (var n = 1; n <= 4; n++)
        buildSession(
          n: n,
          requestId: 'b0000000-0000-4000-8000-00000000000$n',
          date: CalendarDate(2026, 11, 22 + n),
        ),
    ]);
    sends.sent.addAll([
      sentMenu(id: 'send-2', sessionId: sessionId(2), menuVersion: 2),
      sentMenu(
        id: 'send-3',
        sessionId: sessionId(3),
        menuVersion: 2,
        changesRequestedAt: now,
        changesText: 'Sin cebolla',
      ),
      sentMenu(id: 'send-4', sessionId: sessionId(4), menuVersion: 2),
    ]);
    container.read(weekMenusRevisionProvider.notifier).bump();
    await pumpEventQueue();
    expect(
      [for (final m in pending()) (m.session.id, m.state)],
      [
        (sessionId(1), PendingMenuState.notSent),
        (sessionId(3), PendingMenuState.changesRequested),
        (sessionId(4), PendingMenuState.changedSinceSent),
      ],
    );
  });

  test('al pasar la hora no vuelve a leer: la que ya empezó sale y el límite se resalta', () async {
    await start([
      buildSession(
        n: 1,
        date: CalendarDate(2026, 11, 22),
        start: const ClockTime.hm(12, 0),
      ),
      buildSession(
        n: 2,
        date: CalendarDate(2026, 11, 24),
        requestId: 'b0000000-0000-4000-8000-0000000000cc',
      ),
    ]);
    expect(pending(), hasLength(2));
    // El límite de la del martes 24 a las 10:00 es el domingo 22 a las 10:00:
    // ya pasó.
    expect(pending().last.deadlinePassed(now), isTrue);

    // Las 12:30 en Roma: la de hoy a las 12:00 ya empezó.
    now = DateTime.utc(2026, 11, 22, 11, 30);
    container.invalidate(todayNowProvider);
    await pumpEventQueue();
    expect([for (final m in pending()) m.session.id], [sessionId(2)]);
    expect(sends.latestCalls, hasLength(1));
  });

  test('guardar, mandar o «Ricarica» (la revisión) vuelve a leer', () async {
    await start(longBooking());
    expect(pending().single.state, PendingMenuState.noMenu);
    menus.menus[sessionId(8)] = savedLasagneMenu();
    container.read(weekMenusRevisionProvider.notifier).bump();
    await pumpEventQueue();
    expect(sends.latestCalls, hasLength(2));
    expect(pending().single.state, PendingMenuState.notSent);
  });

  test('si una lectura falla: el error, sin reintentar solo; volver a pedirla la lee', () async {
    menus = FakeSessionMenusRepository()
      ..summaryFailure = const MenuFailure(MenuFailureKind.unavailable);
    await start(longBooking());
    expect(container.read(todayPendingMenusProvider).hasError, isTrue);
    await pumpEventQueue();
    expect(menus.summaryCalls, hasLength(1));

    menus.summaryFailure = null;
    container.invalidate(todayMenusDataProvider);
    await pumpEventQueue();
    expect(pending().single.state, PendingMenuState.noMenu);
  });

  test('sin semanas en los próximos 7 días no lee nada', () async {
    await start(buildBooking(weeks: 2, first: CalendarDate(2026, 12, 2)));
    expect(pending(), isEmpty);
    expect(menus.summaryCalls, isEmpty);
    expect(sends.latestCalls, isEmpty);
    expect(sessions.bookingWeeksCalls, isEmpty);
    expect(const WeekMenuSummary().saved, isFalse);
  });
}

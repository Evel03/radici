// «Menús para mandar» de Hoy sin widgets: las semanas de los próximos 7 días
// (día de Roma) que esperan algo con su menú, leídas con una consulta de cada
// cosa para todas (los menús, los últimos envíos y las semanas vivas de sus
// reservas: nunca una por semana), con «Semana k de N» de la reserva entera
// aunque empiece antes de lo que lee la agenda y el límite de 48 h antes de
// la llegada (en la semana 1 de un presupuesto, su plazo si vence antes, con
// una consulta de los plazos). Una semana confirmada cuyo último envío salió
// con una versión anterior del presupuesto sigue pendiente, como en los
// avisos (con una consulta más, solo entonces). Cargando hasta la primera
// lectura con la agenda leída. La hora solo descarta y resalta (no vuelve a
// leer); guardar, mandar, «Ricarica» y una semana que entra sí, y mientras se
// vuelve a leer queda lo de antes. Si una lectura falla, el error, sin
// reintentar solo.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/today/application/today_menus_providers.dart';
import 'package:radici/features/today/application/today_providers.dart';
import 'package:radici/features/today/domain/pending_menus.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/menu_send_fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/quote_fakes.dart';
import '../../../support/quote_fixtures.dart';
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
  late FakeQuotesRepository quotes;
  late ProviderContainer container;

  /// [agenda]: si no es null, la lectura de la agenda espera a que se
  /// complete. [sent]: los envíos que ya salieron.
  Future<void> start(
    List<CookingSession> booking, {
    Completer<void>? agenda,
    List<MenuSendRecord> sent = const [],
  }) async {
    sessions = FakeSessionsRepository(booking)..pendingAgendaFetch = agenda;
    sends = FakeMenuSendsRepository(menus: menus, sent: sent);
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
        quotesRepositoryProvider.overrideWithValue(quotes),
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
    quotes = FakeQuotesRepository();
  });

  group('el presupuesto', () {
    const quoteRequest = 'b0000000-0000-4000-8000-0000000000bb';

    test('la semana 1 de un presupuesto: si su plazo vence antes que el límite del menú, el límite es el plazo (una lectura de los plazos, solo de los pedidos con una semana retenida)', () async {
      // El borrador, preparado el lunes 23 a las 10:00, retiene hasta el
      // martes 24 a las 10:00; el menú del sábado 28 a las 10:00 vencería el
      // jueves 26.
      final hold = DateTime.utc(2026, 11, 24, 9);
      quotes = FakeQuotesRepository(
        quotes: [buildQuote(requestId: quoteRequest, holdUntil: hold)],
      );
      await start([
        buildSession(
          n: 20,
          date: CalendarDate(2026, 11, 28),
          status: SessionStatus.held,
          requestId: quoteRequest,
          requestStatus: RequestStatus.newRequest,
        ),
        ...buildBooking(weeks: 1, first: CalendarDate(2026, 11, 25)),
      ]);

      final byId = {for (final m in pending()) m.session.id: m};
      expect(byId[sessionId(20)]!.deadline, hold);
      expect(byId[sessionId(20)]!.quoteExpires, isTrue);
      // La de la reserva, con el límite del menú.
      expect(byId[sessionId(1)]!.deadline, DateTime.utc(2026, 11, 23, 9));
      expect(byId[sessionId(1)]!.quoteExpires, isFalse);
      expect(quotes.holdCalls, [
        [quoteRequest],
      ]);
    });

    test(
      'si el plazo del presupuesto vence después, manda el límite del menú',
      () async {
        quotes = FakeQuotesRepository(
          quotes: [
            buildQuote(
              requestId: quoteRequest,
              holdUntil: DateTime.utc(2026, 11, 27, 9),
            ),
          ],
        );
        await start([
          buildSession(
            n: 20,
            date: CalendarDate(2026, 11, 28),
            status: SessionStatus.held,
            requestId: quoteRequest,
            requestStatus: RequestStatus.newRequest,
          ),
        ]);
        final menu = pending().single;
        expect(menu.deadline, DateTime.utc(2026, 11, 26, 9));
        expect(menu.quoteExpires, isFalse);
      },
    );

    test('una semana confirmada cuyo último envío llevaba el presupuesto, que después salió desde otra semana, y nadie lo confirmó: pendiente, como en los avisos', () async {
      menus = FakeSessionMenusRepository(
        menus: {sessionId(1): savedLasagneMenu(version: 1)},
      );
      await start(
        buildBooking(weeks: 2, first: CalendarDate(2026, 11, 25)),
        sent: [
          sentMenu(
            id: 'send-1',
            sessionId: sessionId(1),
            quoteId: testQuoteId,
            sentAt: DateTime.utc(2026, 11, 18, 9),
          ),
          // Lo reenvió desde la semana que pasó a ser la primera.
          sentMenu(
            id: 'send-2',
            sessionId: sessionId(2),
            quoteId: testQuoteId,
            sentAt: DateTime.utc(2026, 11, 19, 9),
          ),
        ],
      );

      final menu = pending().single;
      expect(menu.session.id, sessionId(1));
      expect(menu.state, PendingMenuState.sentWithEarlierQuote);
      expect(sends.quoteSendCalls, [
        [testQuoteId],
      ]);
    });

    test('si lo confirmó la clienta, o es el último envío del presupuesto, nada pendiente y ninguna lectura de más', () async {
      menus = FakeSessionMenusRepository(
        menus: {sessionId(1): savedLasagneMenu(version: 1)},
      );
      await start(
        buildBooking(weeks: 1, first: CalendarDate(2026, 11, 25)),
        sent: [
          sentMenu(
            id: 'send-1',
            sessionId: sessionId(1),
            quoteId: testQuoteId,
            confirmedAt: DateTime.utc(2026, 11, 19, 9),
          ),
        ],
      );
      expect(pending(), isEmpty);
      expect(sends.quoteSendCalls, isEmpty);
      expect(quotes.holdCalls, isEmpty);
    });
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

  test('la primera lectura: con la agenda recién leída, carga hasta leer los menús (lo de antes, de una agenda sin leer, no cuenta como «nada que mandar»)', () async {
    final agenda = Completer<void>();
    await start(longBooking(), agenda: agenda);
    // Sin la agenda no hay semanas: no se lee nada.
    expect(sends.latestCalls, isEmpty);

    sends.pendingLatest = Completer<void>();
    agenda.complete();
    await pumpEventQueue();
    expect(sends.latestCalls, [
      [sessionId(8)],
    ]);
    final reading = container.read(todayPendingMenusProvider);
    expect(reading.isLoading, isTrue);
    expect(reading.hasValue, isFalse);

    sends.pendingLatest!.complete();
    await pumpEventQueue();
    expect(pending().single.session.id, sessionId(8));
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

  test(
    'mientras vuelve a leer (guardar, mandar o «Ricarica»), queda lo de antes',
    () async {
      await start(longBooking());
      expect(pending().single.state, PendingMenuState.noMenu);
      menus.menus[sessionId(8)] = savedLasagneMenu();
      sends.pendingLatest = Completer<void>();
      container.read(weekMenusRevisionProvider.notifier).bump();
      await pumpEventQueue();
      expect(sends.latestCalls, hasLength(2));
      expect(container.read(todayPendingMenusProvider).isLoading, isTrue);
      expect(pending().single.state, PendingMenuState.noMenu);

      sends.pendingLatest!.complete();
      await pumpEventQueue();
      expect(container.read(todayPendingMenusProvider).isLoading, isFalse);
      expect(pending().single.state, PendingMenuState.notSent);
    },
  );

  test('una semana que entra (la medianoche de Roma) también deja lo de antes mientras se lee, y aparece cuando se leyó', () async {
    await start([
      // El miércoles 25.
      ...longBooking(),
      // El domingo 29: fuera de la tira del domingo 22, dentro de la del 23.
      buildSession(
        n: 21,
        date: CalendarDate(2026, 11, 29),
        requestId: 'b0000000-0000-4000-8000-0000000000c1',
        name: 'Marta Bianchi',
      ),
    ]);
    expect([for (final m in pending()) m.session.id], [sessionId(8)]);
    sends.pendingLatest = Completer<void>();
    now = DateTime.utc(2026, 11, 23, 9, 30);
    container
      ..invalidate(romeTodayProvider)
      ..invalidate(todayNowProvider);
    await pumpEventQueue();
    expect(sends.latestCalls.last, [sessionId(8), sessionId(21)]);
    expect(container.read(todayPendingMenusProvider).isLoading, isTrue);
    expect([for (final m in pending()) m.session.id], [sessionId(8)]);

    sends.pendingLatest!.complete();
    await pumpEventQueue();
    expect(
      [for (final m in pending()) m.session.id],
      [sessionId(8), sessionId(21)],
    );
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

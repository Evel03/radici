// «Menús para mandar» de Hoy en Dart puro: qué semanas entran (confirmadas,
// de una reserva, de hoy y los 6 días siguientes de Roma, que todavía no
// empezaron), qué le falta a cada una (sin menú, armado sin mandar, cambiado
// después de mandarlo, con cambios pedidos o, en una confirmada, mandado con
// una versión anterior del presupuesto que nadie confirmó, como la regla 8 de
// menu_reminders_due), el límite de 48 h antes de la llegada con la hora de
// Roma (también cuando en el medio cambia la hora; en la semana 1 de un
// presupuesto, su plazo si vence antes) y cuándo se resalta (faltan menos de
// 24 h o ya pasó).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/today/domain/pending_menus.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/menu_send_fakes.dart';
import '../../../support/quote_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  /// Domingo 22/11/2026: la tira va del 22 al 28.
  final today = CalendarDate(2026, 11, 22);

  CookingSession week(
    int n, {
    CalendarDate? date,
    ClockTime start = const ClockTime.hm(10, 0),
    SessionStatus status = SessionStatus.confirmed,
    String? requestId = bookingRequestId,
  }) => buildSession(
    n: n,
    date: date ?? today.addDays(n),
    start: start,
    status: status,
    requestId: requestId,
  );

  group('el límite: 48 h antes de la llegada, con la hora de Roma', () {
    test('mié 25/11 a las 10:00 (UTC+1): el lun 23/11 a las 10:00 de Roma', () {
      final session = week(3, date: CalendarDate(2026, 11, 25));
      expect(sessionArrival(session), DateTime.utc(2026, 11, 25, 9));
      expect(menuDeadlineOf(session), DateTime.utc(2026, 11, 23, 9));
      expect(romeWallClock(menuDeadlineOf(session)).hour, 10);
    });

    test('con el cambio de hora en el medio son 48 h de verdad: lun 30/3 a las 10:00 (UTC+2) vence el sáb 28/3 a las 9:00 (UTC+1)', () {
      final session = week(1, date: CalendarDate(2026, 3, 30));
      expect(sessionArrival(session), DateTime.utc(2026, 3, 30, 8));
      final deadline = menuDeadlineOf(session);
      expect(deadline, DateTime.utc(2026, 3, 28, 8));
      final wall = romeWallClock(deadline);
      expect((wall.day, wall.hour), (28, 9));
    });

    test(
      'se resalta desde 24 h antes del límite y dice que pasó desde el límite',
      () {
        final session = week(3, date: CalendarDate(2026, 11, 25));
        final menu = PendingMenu(
          session: session,
          state: PendingMenuState.notSent,
          deadline: menuDeadlineOf(session),
        );
        final deadline = menu.deadline;
        expect(
          menu.deadlineNear(
            deadline.subtract(const Duration(hours: 24, minutes: 1)),
          ),
          isFalse,
        );
        expect(
          menu.deadlineNear(deadline.subtract(const Duration(hours: 24))),
          isTrue,
        );
        expect(
          menu.deadlinePassed(deadline.subtract(const Duration(minutes: 1))),
          isFalse,
        );
        expect(menu.deadlinePassed(deadline), isTrue);
        expect(
          menu.deadlineNear(deadline.add(const Duration(hours: 5))),
          isTrue,
        );
      },
    );
  });

  group('qué semanas entran', () {
    test('las confirmadas de una reserva de hoy y los 6 días siguientes, por fecha y llegada', () {
      final candidates = pendingMenuCandidates([
        week(6, date: today.addDays(6)),
        week(1, date: today, start: const ClockTime.hm(12, 0)),
        week(2, date: today, start: const ClockTime.hm(9, 0)),
        // Una vieja en shopping_done se ve como confirmada.
        week(3, status: SessionStatus.shoppingDone),
        // Fuera: el día 7, ayer, sin pedido, un presupuesto enviado, una
        // cocinada, una cobrada y una cancelada.
        week(7, date: today.addDays(7)),
        week(8, date: today.addDays(-1)),
        week(9, requestId: null),
        week(10, date: today.addDays(2), status: SessionStatus.held),
        week(11, date: today.addDays(2), status: SessionStatus.cooked),
        week(12, date: today.addDays(2), status: SessionStatus.paid),
        week(13, date: today.addDays(2), status: SessionStatus.cancelled),
      ], today: today);
      expect(
        [for (final s in candidates) s.id],
        [sessionId(2), sessionId(1), sessionId(3), sessionId(6)],
      );
    });

    test('la semana 1 de un presupuesto sin aceptar también (su menú sale con él); las demás de ese presupuesto, no', () {
      const quoteRequest = 'b0000000-0000-4000-8000-0000000000bb';
      final candidates = pendingMenuCandidates([
        week(
          20,
          date: today.addDays(1),
          status: SessionStatus.held,
          requestId: quoteRequest,
        ),
        week(
          21,
          date: today.addDays(8),
          status: SessionStatus.held,
          requestId: quoteRequest,
        ),
        // Otra semana del mismo presupuesto dentro de la tira: sale después
        // de que lo acepte.
        week(
          22,
          date: today.addDays(5),
          status: SessionStatus.held,
          requestId: quoteRequest,
        ),
        // La primera viva cuenta: con la 1 cancelada, la que sigue lleva el
        // presupuesto.
        week(30, date: today.addDays(1), status: SessionStatus.cancelled),
        week(31, date: today.addDays(3), status: SessionStatus.held),
      ], today: today);
      expect(
        [for (final s in candidates) s.id],
        [sessionId(20), sessionId(31)],
      );
    });
  });

  group('qué le falta al menú', () {
    final send = sentMenu(sessionId: sessionId(1), menuVersion: 2);

    test('sin envío: sin menú (o sin platos) o armado sin mandar', () {
      expect(
        pendingMenuState(const WeekMenuSummary(), null),
        PendingMenuState.noMenu,
      );
      expect(
        pendingMenuState(
          const WeekMenuSummary(saved: true, items: 3, version: 1),
          null,
        ),
        PendingMenuState.noMenu,
      );
      expect(
        pendingMenuState(
          const WeekMenuSummary(saved: true, dishes: 2, version: 1),
          null,
        ),
        PendingMenuState.notSent,
      );
    });

    test('mandado y sin cambios: nada (también confirmado)', () {
      const saved = WeekMenuSummary(saved: true, dishes: 2, version: 2);
      expect(pendingMenuState(saved, send), isNull);
      expect(
        pendingMenuState(saved, send.copyWith(confirmedAt: testSentAt)),
        isNull,
      );
    });

    test('cambios pedidos (aunque ya lo haya cambiado) o cambiado después de mandarlo (aunque lo haya confirmado)', () {
      const newer = WeekMenuSummary(saved: true, dishes: 2, version: 3);
      final changes = send.copyWith(
        changesRequestedAt: testSentAt,
        changesText: 'Sin cebolla',
      );
      expect(
        pendingMenuState(
          const WeekMenuSummary(saved: true, dishes: 2, version: 2),
          changes,
        ),
        PendingMenuState.changesRequested,
      );
      expect(
        pendingMenuState(newer, changes),
        PendingMenuState.changesRequested,
      );
      expect(pendingMenuState(newer, send), PendingMenuState.changedSinceSent);
      expect(
        pendingMenuState(newer, send.copyWith(confirmedAt: testSentAt)),
        PendingMenuState.changedSinceSent,
      );
    });
  });

  group('pendingMenus', () {
    test('las que todavía no empezaron y les falta algo, con su estado, su límite y «Semana k de N»', () {
      // Hoy a las 10:30 de Roma: la de hoy a las 10:00 ya empezó.
      final now = DateTime.utc(2026, 11, 22, 9, 30);
      final started = week(1, date: today);
      final later = week(2, date: today, start: const ClockTime.hm(12, 0));
      final sent = week(3);
      final noRow = week(4);
      final menus = pendingMenus(
        [noRow, sent, later, started],
        summaries: {
          sessionId(1): const WeekMenuSummary(),
          sessionId(2): const WeekMenuSummary(
            saved: true,
            dishes: 1,
            version: 1,
          ),
          sessionId(3): const WeekMenuSummary(
            saved: true,
            dishes: 1,
            version: 1,
          ),
        },
        sends: {sessionId(3): sentMenu(sessionId: sessionId(3))},
        positions: {sessionId(2): (week: 2, weeks: 4)},
        now: now,
      );
      expect(
        [for (final m in menus) (m.session.id, m.state)],
        [
          (sessionId(2), PendingMenuState.notSent),
          // Sin fila de menús: como sin menú.
          (sessionId(4), PendingMenuState.noMenu),
        ],
      );
      expect(menus.first.position, (week: 2, weeks: 4));
      expect(menus.last.position, isNull);
      expect(menus.first.deadline, menuDeadlineOf(later));
      // El límite de la de hoy a las 12:00 ya pasó (el viernes 20).
      expect(menus.first.deadlinePassed(now), isTrue);
      expect(menus.first.toString(), isNot(contains('Giulia')));
    });
  });

  group(
    'la semana 1 de un presupuesto: el límite es su plazo si vence antes',
    () {
      const quoteRequest = 'b0000000-0000-4000-8000-0000000000bb';
      // Lunes 23 a las 10:00 de Roma.
      final now = DateTime.utc(2026, 11, 23, 9);
      // El sábado 28 a las 10:00: el menú vence el jueves 26 a las 10:00.
      final weekOne = week(
        6,
        status: SessionStatus.held,
        requestId: quoteRequest,
      );

      List<PendingMenu> withHold(DateTime hold) => pendingMenus(
        [weekOne],
        summaries: const {},
        sends: const {},
        positions: const {},
        now: now,
        quoteHolds: {quoteRequest: hold},
      );

      test('el borrador retiene 24 h (hasta el martes 24 a las 10:00): ese es el límite, y se resalta desde ya', () {
        final hold = DateTime.utc(2026, 11, 24, 9);
        final menu = withHold(hold).single;
        expect(menu.deadline, hold);
        expect(menu.quoteExpires, isTrue);
        expect(menu.deadlineNear(now), isTrue);
      });

      test('mandado con cambios pedidos: vence a las 48 h del envío (el miércoles 25), antes que el menú', () {
        final hold = DateTime.utc(2026, 11, 25, 9);
        final menu = withHold(hold).single;
        expect(menu.deadline, hold);
        expect(menu.quoteExpires, isTrue);
      });

      test(
        'si el plazo vence después del límite del menú, manda el del menú',
        () {
          final menu = withHold(DateTime.utc(2026, 11, 27, 9)).single;
          expect(menu.deadline, menuDeadlineOf(weekOne));
          expect(menu.quoteExpires, isFalse);
        },
      );

      test('una semana confirmada no mira el plazo de un presupuesto', () {
        expect(
          pendingDeadlineOf(week(6), hold: DateTime.utc(2026, 11, 24, 9)),
          (deadline: menuDeadlineOf(week(6)), quoteExpires: false),
        );
      });
    },
  );

  group('mandado con una versión anterior del presupuesto (la regla 8 de menu_reminders_due)', () {
    final now = DateTime.utc(2026, 11, 22, 9, 30);
    const menu = WeekMenuSummary(saved: true, dishes: 2, version: 1);
    // El envío de la semana 3, con el presupuesto, el miércoles 18.
    final earlier = sentMenu(
      id: 'send-1',
      sessionId: sessionId(3),
      quoteId: testQuoteId,
      sentAt: DateTime.utc(2026, 11, 18, 9),
    );
    // Después lo reenvió desde otra semana (la que pasó a ser la primera).
    final later = sentMenu(
      id: 'send-2',
      sessionId: sessionId(9),
      quoteId: testQuoteId,
      sentAt: DateTime.utc(2026, 11, 19, 9),
    );

    List<PendingMenu> pendingFor(
      CookingSession session,
      MenuSendRecord send, {
      Map<String, MenuSendRecord> quoteSends = const {},
    }) => pendingMenus(
      [session],
      summaries: {session.id: menu},
      sends: {session.id: send},
      positions: const {},
      now: now,
      quoteSends: quoteSends,
    );

    test('una semana confirmada cuyo último envío lo llevaba, nadie lo confirmó y salió otro después: pendiente', () {
      final pending = pendingFor(
        week(3),
        earlier,
        quoteSends: {testQuoteId: later},
      ).single;
      expect(pending.state, PendingMenuState.sentWithEarlierQuote);
      expect(pending.deadline, menuDeadlineOf(week(3)));
    });

    test('si la clienta lo confirmó, si es el último del presupuesto o si la semana es retenida: nada', () {
      expect(
        pendingFor(
          week(3),
          earlier.copyWith(confirmedAt: testSentAt),
          quoteSends: {testQuoteId: later},
        ),
        isEmpty,
      );
      expect(
        pendingFor(week(3), earlier, quoteSends: {testQuoteId: earlier}),
        isEmpty,
      );
      expect(
        pendingFor(
          week(3, status: SessionStatus.held),
          earlier,
          quoteSends: {testQuoteId: later},
        ),
        isEmpty,
      );
      // Sin presupuesto, nada que mirar.
      expect(pendingFor(week(3), sentMenu(sessionId: sessionId(3))), isEmpty);
    });

    test('los cambios pedidos van primero; después, el presupuesto anterior; después, el menú cambiado', () {
      expect(
        pendingMenuState(menu, earlier, sentWithEarlierQuote: true),
        PendingMenuState.sentWithEarlierQuote,
      );
      expect(
        pendingMenuState(
          menu,
          earlier.copyWith(
            changesRequestedAt: testSentAt,
            changesText: 'Sin cebolla',
          ),
          sentWithEarlierQuote: true,
        ),
        PendingMenuState.changesRequested,
      );
      expect(
        pendingMenuState(
          const WeekMenuSummary(saved: true, dishes: 2, version: 2),
          earlier,
          sentWithEarlierQuote: true,
        ),
        PendingMenuState.sentWithEarlierQuote,
      );
    });
  });
}

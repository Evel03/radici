// El presupuesto de un pedido como lo lee la cocina: la fila de `quotes` con
// sus semanas y el último envío que lo llevó, y su estado con la misma
// prioridad que la base (client_link_view y private.quote_closed_reason):
// cerrado primero, después sin mandar, cambiado sin reenviar, con cambios
// pedidos y mandado. También el presupuesto de la foto de la vista previa y
// el plazo que dice el mensaje (quote_snapshot.ts).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/quote_fixtures.dart';

void main() {
  group('la fila de quotes', () {
    test('con sus semanas y el último envío que salió, con sus términos', () {
      final row = quoteRow(
        version: 2,
        sentAt: '2026-11-22T13:32:00+00:00',
        lastSentAt: '2026-11-22T18:00:00+00:00',
        holdUntil: '2026-11-24T18:00:00+00:00',
        sends: [
          {
            'id': 'send-1',
            'session_id': quoteSessionId(1),
            'menu_version': 1,
            'sent_at': '2026-11-22T13:32:00+00:00',
            'sent_via': ['email'],
            'client_confirmed_at': null,
            'changes_requested_at': '2026-11-22T15:00:00+00:00',
            'changes_text': 'Sin cebolla, por favor',
            'quote_terms': quoteTermsJson(),
          },
          {
            'id': 'send-2',
            'session_id': quoteSessionId(1),
            'menu_version': 2,
            'sent_at': '2026-11-22T18:00:00+00:00',
            'sent_via': ['whatsapp'],
            'client_confirmed_at': null,
            'changes_requested_at': null,
            'changes_text': null,
            'quote_terms': quoteTermsJson(),
          },
        ],
      );

      final quote = RequestQuote.fromRow(row);

      expect(quote.id, testQuoteId);
      expect(quote.requestId, 'req-1');
      expect(quote.version, 2);
      expect(quote.serviceCents, 56000);
      expect(quote.wasSent, isTrue);
      expect(quote.lastSentOn, DateTime.utc(2026, 11, 22, 18));
      expect(quote.holdUntil, DateTime.utc(2026, 11, 24, 18));
      expect(quote.sessions, hasLength(4));
      expect(quote.sessions.first.start, const ClockTime.hm(10, 0));
      expect(quote.sessions.first.status, SessionStatus.held);
      // De los envíos, el más nuevo (la consulta ya trae solo ese).
      expect(quote.lastSend!.id, 'send-2');
      expect(quote.changesRequested, isFalse);
      expect(quote.sentTerms, quote.currentTerms);
      expect(quote.sentTerms!.totalCents, 56000);
    });

    test('un borrador: sin envío ni términos que salieron', () {
      final quote = RequestQuote.fromRow(quoteRow());
      expect(quote.wasSent, isFalse);
      expect(quote.lastSend, isNull);
      expect(quote.sentTerms, isNull);
      expect(quote.isOpen, isTrue);
    });

    test('unos términos que no se pueden leer quedan en null (no cambia el presupuesto)', () {
      final quote = RequestQuote.fromRow(
        quoteRow(
          sentAt: '2026-11-22T13:32:00+00:00',
          sends: [
            {
              'id': 'send-1',
              'session_id': quoteSessionId(1),
              'menu_version': 1,
              'sent_at': '2026-11-22T13:32:00+00:00',
              'sent_via': ['email'],
              'client_confirmed_at': null,
              'changes_requested_at': null,
              'changes_text': null,
              'quote_terms': {'quoteId': testQuoteId},
            },
          ],
        ),
      );
      expect(quote.sentTerms, isNull);
      expect(quote.changedSinceSent, isFalse);
    });

    test('una fila rota lanza FormatException', () {
      for (final broken in <Map<String, dynamic>>[
        {...quoteRow(), 'id': null},
        {...quoteRow(), 'version': 0},
        {...quoteRow(), 'service_cents': -1},
        {...quoteRow(), 'created_at': 'ayer'},
        {...quoteRow(), 'weeks': 'semanas'},
        {
          ...quoteRow(),
          'weeks': [
            quoteSessionRow(id: quoteSessionId(1), status: 'hirviendo'),
          ],
        },
        {
          ...quoteRow(),
          'weeks': [quoteSessionRow(id: quoteSessionId(1), startTime: 'diez')],
        },
      ]) {
        expect(() => RequestQuote.fromRow(broken), throwsFormatException);
      }
    });

    test('toString no muestra el mensaje de la clienta', () {
      final quote = buildQuote(
        sent: true,
        lastSend: quoteSend(
          changesRequestedAt: DateTime.utc(2026, 11, 22, 15),
          changesText: 'Mi hija es celíaca',
        ),
      );
      expect('$quote', isNot(contains('celíaca')));
    });
  });

  group('los términos de ahora', () {
    test('las semanas vivas por fecha, llegada e id; el total es la suma', () {
      final sessions = quoteSessions(
        weeks: 3,
        statuses: {2: SessionStatus.cancelled},
      ).reversed.toList();
      final quote = buildQuote(sessions: sessions);
      final terms = quote.currentTerms;
      expect(
        [for (final w in terms.weeks) w.sessionId],
        [quoteSessionId(1), quoteSessionId(3)],
      );
      expect(terms.totalCents, 28000);
      expect(quote.firstWeek!.sessionId, quoteSessionId(1));
    });

    test('dos el mismo día: primero la que llega antes, y con la misma hora, por id', () {
      final day = CalendarDate(2026, 11, 30);
      final quote = buildQuote(
        sessions: [
          QuoteSession(
            id: 'b',
            date: day,
            start: const ClockTime.hm(10, 0),
            cookMinutes: 60,
            serviceCents: 1,
            status: SessionStatus.held,
          ),
          QuoteSession(
            id: 'a',
            date: day,
            start: const ClockTime.hm(10, 0),
            cookMinutes: 60,
            serviceCents: 1,
            status: SessionStatus.held,
          ),
          QuoteSession(
            id: 'c',
            date: day,
            start: const ClockTime.hm(9, 0),
            cookMinutes: 60,
            serviceCents: 1,
            status: SessionStatus.held,
          ),
        ],
      );
      expect(
        [for (final w in quote.currentTerms.weeks) w.sessionId],
        ['c', 'a', 'b'],
      );
    });
  });

  group('el estado', () {
    final now = quoteNow;

    test('un borrador a tiempo: sin mandar', () {
      expect(buildQuote().statusAt(now), QuoteStatus.draft);
    });

    test(
      'un borrador que pasó su plazo de 24 h: vencido (también sin el cron)',
      () {
        final quote = buildQuote(holdUntil: now);
        expect(quote.statusAt(now), QuoteStatus.expired);
        expect(quote.closedOn(QuoteStatus.expired), now);
        expect(
          quote.statusAt(now.subtract(const Duration(minutes: 1))),
          QuoteStatus.draft,
        );
      },
    );

    test('mandado y a tiempo, con los términos que salieron', () {
      expect(buildQuote(sent: true).statusAt(now), QuoteStatus.sent);
    });

    test('la clienta pidió cambios en el último envío', () {
      final quote = buildQuote(
        sent: true,
        lastSend: quoteSend(
          changesRequestedAt: DateTime.utc(2026, 11, 22, 15),
          changesText: 'Sin cebolla',
        ),
      );
      expect(quote.statusAt(now), QuoteStatus.changesRequested);
    });

    test(
      'otro precio después de mandarlo: cambiado (hay que mandarlo de nuevo)',
      () {
        final sentSessions = quoteSessions();
        final quote = buildQuote(
          sent: true,
          sentTerms: termsOf(sentSessions),
          sessions: quoteSessions(serviceCents: 15000),
        );
        expect(quote.changedSinceSent, isTrue);
        expect(quote.statusAt(now), QuoteStatus.changed);
      },
    );

    test('una semana movida o cancelada después de mandarlo: cambiado', () {
      final sentSessions = quoteSessions();
      final moved = [
        for (final s in sentSessions)
          s.id == quoteSessionId(2) ? s.copyWith(date: s.date.addDays(1)) : s,
      ];
      expect(
        buildQuote(
          sent: true,
          sentTerms: termsOf(sentSessions),
          sessions: moved,
        ).statusAt(now),
        QuoteStatus.changed,
      );
      final otherTime = [
        for (final s in sentSessions)
          s.id == quoteSessionId(1)
              ? s.copyWith(start: const ClockTime.hm(11, 0))
              : s,
      ];
      expect(
        buildQuote(
          sent: true,
          sentTerms: termsOf(sentSessions),
          sessions: otherTime,
        ).statusAt(now),
        QuoteStatus.changed,
      );
      final cancelled = quoteSessions(statuses: {4: SessionStatus.cancelled});
      expect(
        buildQuote(
          sent: true,
          sentTerms: termsOf(sentSessions),
          sessions: cancelled,
        ).statusAt(now),
        QuoteStatus.changed,
      );
    });

    test(
      'cambiado gana sobre los cambios pedidos: lo que falta es mandarlo',
      () {
        final sentSessions = quoteSessions();
        final quote = buildQuote(
          sent: true,
          sentTerms: termsOf(sentSessions),
          sessions: quoteSessions(serviceCents: 13000),
          lastSend: quoteSend(
            changesRequestedAt: DateTime.utc(2026, 11, 22, 15),
            changesText: 'Más barato',
          ),
        );
        expect(quote.statusAt(now), QuoteStatus.changed);
        expect(quote.changesRequested, isTrue);
      },
    );

    test('pasado el plazo, vencido: gana sobre cambiado y sobre los cambios pedidos', () {
      final quote = buildQuote(
        sent: true,
        holdUntil: now,
        sentTerms: termsOf(quoteSessions()),
        sessions: quoteSessions(serviceCents: 1),
        lastSend: quoteSend(
          changesRequestedAt: DateTime.utc(2026, 11, 22, 15),
          changesText: 'x',
        ),
      );
      expect(quote.statusAt(now), QuoteStatus.expired);
    });

    test('cerrado: aceptado, rechazado, retirado o vencido por el cron, en ese orden', () {
      final at = DateTime.utc(2026, 11, 23, 8);
      expect(
        buildQuote(sent: true, acceptedAt: at).statusAt(now),
        QuoteStatus.accepted,
      );
      expect(
        buildQuote(sent: true, declinedAt: at).statusAt(now),
        QuoteStatus.declined,
      );
      expect(buildQuote(withdrawnAt: at).statusAt(now), QuoteStatus.withdrawn);
      expect(
        buildQuote(sent: true, expiredAt: at).statusAt(now),
        QuoteStatus.expired,
      );
      // Aceptado aunque el plazo ya haya pasado: lo cerrado manda.
      expect(
        buildQuote(sent: true, acceptedAt: at, holdUntil: at).statusAt(now),
        QuoteStatus.accepted,
      );
      for (final quote in [
        buildQuote(sent: true, acceptedAt: at),
        buildQuote(sent: true, declinedAt: at),
        buildQuote(withdrawnAt: at),
        buildQuote(sent: true, expiredAt: at),
      ]) {
        expect(quote.isOpen, isFalse);
        expect(quote.closedOn(quote.statusAt(now)), at);
      }
    });

    test('abierto para la base aunque el plazo haya pasado (el cron todavía no lo cerró)', () {
      final quote = buildQuote(sent: true, holdUntil: now);
      expect(quote.isOpen, isTrue);
      expect(quote.statusAt(now).isOpen, isFalse);
    });
  });

  group('las semanas que se muestran', () {
    test(
      'abierto, las de ahora; cerrado, las que salieron; nunca salió, ninguna',
      () {
        final sentSessions = quoteSessions();
        final open = buildQuote(
          sent: true,
          sentTerms: termsOf(sentSessions),
          sessions: quoteSessions(serviceCents: 15000),
        );
        expect(open.termsFor(QuoteStatus.changed)!.totalCents, 60000);
        final declined = buildQuote(
          sent: true,
          declinedAt: quoteNow,
          sentTerms: termsOf(sentSessions),
          sessions: quoteSessions(
            statuses: {for (var w = 1; w <= 4; w++) w: SessionStatus.cancelled},
          ),
        );
        expect(declined.termsFor(QuoteStatus.declined)!.totalCents, 56000);
        final withdrawnDraft = buildQuote(withdrawnAt: quoteNow);
        expect(withdrawnDraft.termsFor(QuoteStatus.withdrawn), isNull);
      },
    );
  });

  group('lo que se puede hacer', () {
    test(
      'sin mandar: mandarlo es lo que falta; el menú, otro precio y retirarlo',
      () {
        expect(quoteActionsFor(QuoteStatus.draft, hasWeeks: true), (
          send: true,
          resend: false,
          sendIsPrimary: true,
          editMenu: true,
          changePrice: true,
          withdraw: true,
        ));
      },
    );

    test('mandado y a la espera: mandarlo de nuevo no es lo que falta', () {
      expect(quoteActionsFor(QuoteStatus.sent, hasWeeks: true), (
        send: false,
        resend: true,
        sendIsPrimary: false,
        editMenu: true,
        changePrice: true,
        withdraw: true,
      ));
    });

    test(
      'cambiado o con cambios pedidos: mandarlo de nuevo es lo que falta',
      () {
        for (final status in [
          QuoteStatus.changed,
          QuoteStatus.changesRequested,
        ]) {
          final actions = quoteActionsFor(status, hasWeeks: true);
          expect(actions.resend, isTrue);
          expect(actions.sendIsPrimary, isTrue);
        }
      },
    );

    test('sin semanas vivas solo se retira', () {
      expect(quoteActionsFor(QuoteStatus.changed, hasWeeks: false), (
        send: false,
        resend: false,
        sendIsPrimary: false,
        editMenu: false,
        changePrice: false,
        withdraw: true,
      ));
    });

    test('cerrado, nada', () {
      for (final status in [
        QuoteStatus.accepted,
        QuoteStatus.declined,
        QuoteStatus.withdrawn,
        QuoteStatus.expired,
      ]) {
        final actions = quoteActionsFor(status, hasWeeks: true);
        expect([
          actions.send,
          actions.resend,
          actions.editMenu,
          actions.changePrice,
          actions.withdraw,
        ], everyElement(isFalse));
      }
    });
  });

  group('los términos de la base', () {
    test('se leen enteros', () {
      final terms = QuoteTerms.tryParse(quoteTermsJson())!;
      expect(terms.quoteId, testQuoteId);
      expect(terms.weeks, hasLength(4));
      expect(terms.weeks.first.date, CalendarDate(2026, 11, 30));
      expect(terms.weeks.first.cookMinutes, 180);
      expect(terms.totalCents, 56000);
    });

    test('nunca a medias: un total que no es la suma, fuera de orden, una hora rota…', () {
      final good = quoteTermsJson();
      final weeks = (good['weeks'] as List).cast<Map<String, dynamic>>();
      for (final broken in <Object?>[
        null,
        'términos',
        {...good, 'totalCents': 1},
        {...good, 'quoteId': ''},
        {...good, 'weeks': weeks.reversed.toList()},
        {
          ...good,
          'weeks': [
            {...weeks.first, 'start': '10:00:00'},
            ...weeks.skip(1),
          ],
        },
        {
          ...good,
          'weeks': [
            {...weeks.first, 'serviceCents': -1},
            ...weeks.skip(1),
          ],
        },
        {
          ...good,
          'weeks': [for (var i = 0; i < 9; i++) weeks.first],
          'totalCents': 9 * 14000,
        },
      ]) {
        expect(QuoteTerms.tryParse(broken), isNull, reason: '$broken');
      }
    });

    test('sin semanas vivas: un total de 0', () {
      final terms = QuoteTerms.tryParse({
        'quoteId': testQuoteId,
        'totalCents': 0,
        'weeks': <Object>[],
      });
      expect(terms!.weeks, isEmpty);
    });
  });

  group('el presupuesto de la foto', () {
    test('se lee entero: la versión, las semanas, el total y las horas', () {
      final quote = PreviewQuote.tryParse(snapshotQuoteJson(version: 2))!;
      expect(quote.version, 2);
      expect(quote.weeks, hasLength(2));
      expect(quote.weeks.first.date, CalendarDate(2026, 11, 30));
      expect(quote.weeks.first.start, const ClockTime.hm(10, 0));
      expect(quote.totalCents, 28000);
      expect(quote.holdHours, 48);
    });

    test('no se muestra si no cierra (como readSnapshotQuote)', () {
      final good = snapshotQuoteJson();
      final weeks = (good['weeks'] as List).cast<Map<String, dynamic>>();
      for (final broken in <Object?>[
        null,
        {...good, 'totalCents': 1},
        {...good, 'version': 0},
        {...good, 'holdHours': 0},
        {...good, 'firstStart': '2026-12-07T10:00'},
        {...good, 'weeks': <Object>[]},
        {...good, 'weeks': weeks.reversed.toList()},
      ]) {
        expect(PreviewQuote.tryParse(broken), isNull, reason: '$broken');
      }
    });
  });

  group('el plazo si sale ahora', () {
    // La primera llegada: lunes 30/11 a las 10:00 en Roma (09:00 UTC).
    final first = CalendarDate(2026, 11, 30);
    const start = ClockTime.hm(10, 0);

    test('las horas, si alcanzan antes de la primera llegada (justo a la hora, también)', () {
      expect(
        quoteDeadline(
          holdHours: 48,
          firstDate: first,
          firstStart: start,
          now: DateTime.utc(2026, 11, 23, 9),
        ),
        const QuoteDeadlineHours(48),
      );
      expect(
        quoteDeadline(
          holdHours: 48,
          firstDate: first,
          firstStart: start,
          now: DateTime.utc(2026, 11, 28, 9),
        ),
        const QuoteDeadlineHours(48),
      );
    });

    test('si no, la primera llegada', () {
      expect(
        quoteDeadline(
          holdHours: 48,
          firstDate: first,
          firstStart: start,
          now: DateTime.utc(2026, 11, 28, 9, 1),
        ),
        QuoteDeadlineFirstArrival(first, start),
      );
    });

    test('la llegada es hora de Roma, también con el horario de verano', () {
      // Lunes 1/6/2026 a las 10:00 en Roma son las 08:00 UTC.
      final june = CalendarDate(2026, 6, 1);
      expect(
        quoteDeadline(
          holdHours: 48,
          firstDate: june,
          firstStart: start,
          now: DateTime.utc(2026, 5, 30, 8),
        ),
        const QuoteDeadlineHours(48),
      );
      expect(
        quoteDeadline(
          holdHours: 48,
          firstDate: june,
          firstStart: start,
          now: DateTime.utc(2026, 5, 30, 8, 1),
        ),
        QuoteDeadlineFirstArrival(june, start),
      );
    });
  });

  group('el precio escrito', () {
    test('en euros, a centavos sin double', () {
      expect(readQuotePrice('560'), (cents: 56000, issue: null));
      expect(readQuotePrice('560,50'), (cents: 56050, issue: null));
      expect(readQuotePrice('0'), (cents: 0, issue: null));
    });

    test('vacío, que no es un importe o de más', () {
      expect(readQuotePrice('  ').issue, QuotePriceIssue.required);
      expect(readQuotePrice('cinco').issue, QuotePriceIssue.invalid);
      expect(readQuotePrice('100000,01').issue, QuotePriceIssue.tooHigh);
      expect(readQuotePrice('100000').issue, isNull);
    });
  });
}

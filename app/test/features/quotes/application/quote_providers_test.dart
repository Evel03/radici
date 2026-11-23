// El presupuesto de un pedido sin widgets: se lee con la RLS y se vuelve a
// leer cuando una de sus semanas se mueve o se cancela; otro precio y
// retirarlo pasan por la función chef y, si salen (o si la base dice que ya
// cambió), el presupuesto y el pedido se vuelven a leer. También cuándo el
// pedido de la bandeja quedó viejo frente a su presupuesto.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/quotes/application/quote_providers.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/quote_fakes.dart';
import '../../../support/quote_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  late FakeChefRequestsRepository requests;
  late FakeSessionsRepository sessions;
  late FakeQuotesRepository quotes;
  late ProviderContainer container;

  /// Las semanas `held` del presupuesto, también en las sesiones (las que se
  /// mueven o se cancelan desde la ficha).
  List<CookingSession> heldWeeks() => [
    for (final week in quoteSessions())
      buildSession(
        id: week.id,
        date: week.date,
        status: SessionStatus.held,
        requestId: 'req-1',
        requestStatus: RequestStatus.quoted,
      ),
  ];

  Future<void> open({RequestQuote? quote, ChefRequest? request}) async {
    requests = FakeChefRequestsRepository([
      request ??
          buildRequest(status: RequestStatus.quoted, seenAt: testNow, weeks: 4),
    ]);
    sessions = FakeSessionsRepository(heldWeeks());
    quotes = FakeQuotesRepository(
      requests: requests,
      sessions: sessions,
      quotes: [?quote],
      now: () => quoteNow,
    );
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: chefUser),
        ),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        chefRequestsRepositoryProvider.overrideWithValue(requests),
        sessionsRepositoryProvider.overrideWithValue(sessions),
        quotesRepositoryProvider.overrideWithValue(quotes),
        clockProvider.overrideWithValue(() => quoteNow),
      ],
    );
    // La sesión de Evelyn, cargada (sin ella no hay cocina que leer).
    container.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
    container
      ..listen(chefInboxProvider, (_, _) {})
      ..listen(requestQuoteProvider('req-1'), (_, _) {});
  }

  Future<RequestQuote?> read() =>
      container.read(requestQuoteProvider('req-1').future);

  group('requestQuoteProvider', () {
    test('el último presupuesto del pedido; null si nunca tuvo', () async {
      await open(quote: buildQuote(sent: true));
      expect((await read())!.id, testQuoteId);
      expect(quotes.fetches, ['req-1']);

      await open();
      expect(await read(), isNull);
    });

    test(
      'una semana movida desde la ficha: se vuelve a leer y dice que cambió',
      () async {
        await open(quote: buildQuote(sent: true));
        expect((await read())!.statusAt(quoteNow), QuoteStatus.sent);

        await container
            .read(sessionCommandsProvider)
            .move(
              sessions.sessions[quoteSessionId(2)]!,
              date: quoteSessions()[1].date.addDays(1),
              start: const ClockTime.hm(10, 0),
            );
        await pumpEventQueue();

        expect(quotes.fetches, hasLength(2));
        expect((await read())!.statusAt(quoteNow), QuoteStatus.changed);
      },
    );

    test('si no se puede leer, el error (sin reintentar solo)', () async {
      await open(quote: buildQuote());
      quotes.fetchFailure = const QuoteFailure(QuoteFailureKind.unavailable);
      container.invalidate(requestQuoteProvider('req-1'));
      await expectLater(read(), throwsA(isA<QuoteFailure>()));
      // La lectura de antes y la que falló: no reintenta sola.
      await pumpEventQueue();
      expect(quotes.fetches, hasLength(2));
    });
  });

  group('otro precio', () {
    test('se reparte entre las semanas vivas; el presupuesto y el pedido se vuelven a leer', () async {
      await open(quote: buildQuote(sent: true));
      final quote = (await read())!;
      quotes.pendingPrice = Completer<void>();

      final change = container
          .read(quoteCommandsProvider)
          .changePrice(quote, 50000);
      // Mientras espera, sus botones van deshabilitados.
      expect(container.read(quoteBusyProvider), {testQuoteId});
      quotes.pendingPrice!.complete();
      final terms = await change;

      expect(container.read(quoteBusyProvider), isEmpty);
      expect(quotes.priceCalls, [(quoteId: testQuoteId, cents: 50000)]);
      expect(
        [for (final w in terms.weeks) w.serviceCents],
        [12500, 12500, 12500, 12500],
      );
      final fresh = (await read())!;
      expect(fresh.currentTerms.totalCents, 50000);
      // Ya había salido: hay que mandarlo de nuevo.
      expect(fresh.statusAt(quoteNow), QuoteStatus.changed);
      expect(quotes.fetches, hasLength(2));
    });

    test('cerrado mientras tanto: falla, y se vuelve a leer (el detalle muestra lo de ahora)', () async {
      await open(quote: buildQuote(sent: true));
      final quote = (await read())!;
      quotes.priceFailure = const QuoteFailure(QuoteFailureKind.closed);

      await expectLater(
        container.read(quoteCommandsProvider).changePrice(quote, 1000),
        throwsA(
          isA<QuoteFailure>().having(
            (f) => f.kind,
            'kind',
            QuoteFailureKind.closed,
          ),
        ),
      );
      await read();
      expect(quotes.fetches, hasLength(2));
      expect(container.read(quoteBusyProvider), isEmpty);
    });

    test('sin conexión: falla sin volver a leer nada', () async {
      await open(quote: buildQuote(sent: true));
      final quote = (await read())!;
      quotes.priceFailure = const QuoteFailure(QuoteFailureKind.unavailable);
      await expectLater(
        container.read(quoteCommandsProvider).changePrice(quote, 1000),
        throwsA(isA<QuoteFailure>()),
      );
      await pumpEventQueue();
      expect(quotes.fetches, hasLength(1));
    });
  });

  group('retirarlo', () {
    test(
      'sus semanas retenidas se cancelan y el pedido vuelve a nuevo',
      () async {
        await open(quote: buildQuote(sent: true));
        await container.read(chefInboxProvider.future);
        final quote = (await read())!;

        final withdrawn = await container
            .read(quoteCommandsProvider)
            .withdraw(quote);
        await pumpEventQueue();

        expect(withdrawn.cancelled, 4);
        expect(quotes.withdrawCalls, [testQuoteId]);
        final fresh = (await read())!;
        expect(fresh.statusAt(quoteNow), QuoteStatus.withdrawn);
        expect(fresh.liveSessions, isEmpty);
        final request = container
            .read(chefInboxProvider)
            .value!
            .singleWhere((r) => r.id == 'req-1');
        expect(request.status, RequestStatus.newRequest);
      },
    );
  });

  group('el pedido de la bandeja frente a su presupuesto', () {
    final at = DateTime.utc(2026, 11, 23, 8);

    test('salió desde otro teléfono, la clienta contestó, se retiró o venció: quedó viejo', () {
      final sent = buildQuote(sent: true);
      expect(
        requestLooksStale(RequestStatus.newRequest, sent, QuoteStatus.sent),
        isTrue,
      );
      final accepted = buildQuote(sent: true, acceptedAt: at);
      expect(
        requestLooksStale(RequestStatus.quoted, accepted, QuoteStatus.accepted),
        isTrue,
      );
      final declined = buildQuote(sent: true, declinedAt: at);
      expect(
        requestLooksStale(RequestStatus.quoted, declined, QuoteStatus.declined),
        isTrue,
      );
      final withdrawn = buildQuote(sent: true, withdrawnAt: at);
      expect(
        requestLooksStale(
          RequestStatus.quoted,
          withdrawn,
          QuoteStatus.withdrawn,
        ),
        isTrue,
      );
      final expired = buildQuote(sent: true, expiredAt: at);
      expect(
        requestLooksStale(RequestStatus.quoted, expired, QuoteStatus.expired),
        isTrue,
      );
    });

    test('al día: un borrador con el pedido nuevo, uno mandado con el pedido enviado', () {
      expect(
        requestLooksStale(
          RequestStatus.newRequest,
          buildQuote(),
          QuoteStatus.draft,
        ),
        isFalse,
      );
      expect(
        requestLooksStale(
          RequestStatus.quoted,
          buildQuote(sent: true),
          QuoteStatus.changed,
        ),
        isFalse,
      );
      // Vencido por el plazo, el cron todavía no pasó el pedido a expired.
      expect(
        requestLooksStale(
          RequestStatus.quoted,
          buildQuote(sent: true, holdUntil: at),
          QuoteStatus.expired,
        ),
        isFalse,
      );
      // Un borrador que venció deja el pedido nuevo.
      expect(
        requestLooksStale(
          RequestStatus.newRequest,
          buildQuote(holdUntil: at),
          QuoteStatus.expired,
        ),
        isFalse,
      );
    });

    test('un pedido que siguió por otro camino (rechazado o confirmado sin presupuesto) no', () {
      final withdrawn = buildQuote(withdrawnAt: at);
      for (final status in [
        RequestStatus.rejected,
        RequestStatus.accepted,
        RequestStatus.declined,
        RequestStatus.expired,
      ]) {
        expect(
          requestLooksStale(status, withdrawn, QuoteStatus.withdrawn),
          isFalse,
          reason: status.name,
        );
      }
    });
  });
}

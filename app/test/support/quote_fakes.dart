// El presupuesto "en el servidor", en memoria, como la función chef y la
// lectura de `quotes` (contrato chef-api §14, migración
// 20261121120000_quotes.sql): preparar uno valida como la base (un pedido que
// no está `new` da requestNotNew; uno de cambios, requestNotQuotable; uno con
// otro abierto, quoteExists; una fecha marcada busy, slotTaken) y, con
// [sessions], crea sus semanas `held` (la ficha de la sesión y el menú las
// leen). Otro precio se reparte entre las semanas vivas como split_cents y
// retirarlo cancela las retenidas y devuelve el pedido a `new`. La lectura
// toma las semanas de ahora de [sessions] (así una semana movida o cancelada
// cambia los términos). Cada pedido se aplica en cuanto llega: los
// `pending…` demoran solo la respuesta y [loseNextCreateResponse] crea el
// presupuesto y pierde la respuesta.
import 'dart:async';

import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/quotes/domain/quote_api.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import 'fakes.dart';
import 'request_fixtures.dart';

class FakeQuotesRepository implements QuotesRepository {
  FakeQuotesRepository({
    this.requests,
    this.sessions,
    Iterable<RequestQuote> quotes = const [],
    DateTime Function()? now,
  }) : quotes = {for (final quote in quotes) quote.requestId: quote},
       now = now ?? (() => testNow);

  /// Los pedidos "en el servidor" (su estado manda, como en la base).
  final FakeChefRequestsRepository? requests;

  /// Las sesiones "en el servidor": las semanas que crea un presupuesto y las
  /// que se mueven o se cancelan.
  final FakeSessionsRepository? sessions;

  /// El último presupuesto de cada pedido.
  final Map<String, RequestQuote> quotes;

  final DateTime Function() now;

  /// Estado de cada fecha en el dryRun (ok por defecto).
  final Map<CalendarDate, BookingDayStatus> statuses = {};
  ClockTime suggestedStart = const ClockTime.hm(10, 0);

  /// Si no son null, la operación falla con esto.
  BookingFailure? checksFailure;
  BookingFailure? createFailure;
  QuoteFailure? fetchFailure;
  QuoteFailure? priceFailure;
  QuoteFailure? withdrawFailure;

  /// Si no son null, la respuesta espera a que se completen.
  Completer<void>? pendingCreate;
  Completer<void>? pendingPrice;
  Completer<void>? pendingWithdraw;

  /// La próxima creación se guarda pero su respuesta se pierde
  /// (unavailable).
  bool loseNextCreateResponse = false;

  final List<CreateQuoteRequest> calls = [];
  final List<({String quoteId, int cents})> priceCalls = [];
  final List<String> withdrawCalls = [];
  final List<String> fetches = [];

  List<CreateQuoteRequest> get dryRuns => [
    for (final call in calls)
      if (call.dryRun) call,
  ];

  List<CreateQuoteRequest> get creations => [
    for (final call in calls)
      if (!call.dryRun) call,
  ];

  int _created = 0;

  @override
  Future<RequestQuote?> fetchLatestQuote({
    required String chefId,
    required String requestId,
  }) async {
    fetches.add(requestId);
    final failure = fetchFailure;
    if (failure != null) throw failure;
    final quote = quotes[requestId];
    return quote == null ? null : _withSessionsOfNow(quote);
  }

  /// [quote] con sus semanas como están ahora en [sessions] (movidas o
  /// canceladas por la ficha).
  RequestQuote _withSessionsOfNow(RequestQuote quote) {
    final server = sessions;
    if (server == null) return quote;
    return quote.copyWith(
      sessions: [
        for (final week in quote.sessions)
          switch (server.sessions[week.id]) {
            final session? => week.copyWith(
              date: session.date,
              start: session.start,
              cookMinutes: session.cookMinutes,
              serviceCents: session.serviceCents,
              status: session.status,
            ),
            null => week,
          },
      ],
    );
  }

  @override
  Future<QuoteDraft> createQuote(CreateQuoteRequest request) async {
    calls.add(request);
    final pending = request.dryRun ? null : pendingCreate;
    BookingFailure? refused = request.dryRun ? checksFailure : createFailure;
    final current = requests?.requests[request.requestId];
    if (refused == null && current != null) {
      if (current.type == RequestType.change) {
        refused = const BookingFailure(BookingFailureKind.requestNotQuotable);
      } else if (current.status != RequestStatus.newRequest) {
        refused = BookingFailure(
          BookingFailureKind.requestNotNew,
          requestStatus: current.status.name,
        );
      }
    }
    final open = quotes[request.requestId];
    if (refused == null && open != null && open.isOpen) {
      refused = const BookingFailure(BookingFailureKind.quoteExists);
    }
    final busy = request.dates
        .where((date) => statuses[date] == BookingDayStatus.busy)
        .firstOrNull;
    if (refused == null && !request.dryRun && busy != null) {
      refused = BookingFailure(BookingFailureKind.slotTaken, date: busy);
    }
    final split = splitServiceCents(
      request.serviceTotalCents ?? 0,
      request.dates.length,
    );
    QuoteDraft? draft;
    if (refused == null) {
      draft = request.dryRun
          ? QuoteDraft(
              dryRun: true,
              requestId: request.requestId,
              clientId: testClientId,
              weeks: [
                for (final (i, date) in request.dates.indexed)
                  BookingWeek(
                    date: date,
                    start: request.start ?? suggestedStart,
                    cookMinutes: request.cookMinutes,
                    status: statuses[date] ?? BookingDayStatus.ok,
                    suggestedStart: suggestedStart,
                    serviceCents: split[i],
                  ),
              ],
            )
          : _create(request, split, current);
    }
    if (pending != null) await pending.future;
    if (refused != null) throw refused;
    if (!request.dryRun && loseNextCreateResponse) {
      loseNextCreateResponse = false;
      throw const BookingFailure(BookingFailureKind.unavailable);
    }
    return draft!;
  }

  /// Crea el presupuesto (y, con [sessions], sus semanas `held`) y lo
  /// guarda; el pedido queda visto.
  QuoteDraft _create(
    CreateQuoteRequest request,
    List<int> split,
    ChefRequest? current,
  ) {
    final n = ++_created;
    final quoteId = 'quote-$n';
    final created = now().toUtc();
    final hold = created.add(const Duration(hours: 24));
    final start = request.start ?? suggestedStart;
    final weeks = [
      for (final (i, date) in request.dates.indexed)
        QuoteSession(
          id: '$quoteId-${i + 1}',
          date: date,
          start: start,
          cookMinutes: request.cookMinutes,
          serviceCents: split[i],
          status: SessionStatus.held,
        ),
    ];
    // Como la base: solo cuentan los que salieron (un borrador que nunca
    // salió no gasta un número).
    final previous = quotes[request.requestId];
    quotes[request.requestId] = RequestQuote(
      id: quoteId,
      requestId: request.requestId,
      version: previous == null
          ? 1
          : previous.wasSent
          ? previous.version + 1
          : previous.version,
      serviceCents: request.serviceTotalCents ?? 0,
      holdUntil: hold,
      createdAt: created,
      sessions: weeks,
    );
    final server = requests;
    if (server != null && current != null && current.seenAt == null) {
      server.requests[current.id] = current.copyWith(
        seenAt: DateTime.utc(2026, 10, 19, 12),
      );
    }
    final repository = sessions;
    if (repository != null) {
      for (final week in weeks) {
        repository.sessions[week.id] = CookingSession(
          id: week.id,
          chefId: testChefId,
          clientId: current?.clientId ?? testClientId,
          requestId: request.requestId,
          date: week.date,
          start: week.start,
          cookMinutes: week.cookMinutes,
          shopMinutes: 0,
          gapMinutes: 30,
          portions: request.portions ?? 0,
          status: SessionStatus.held,
          serviceCents: week.serviceCents,
          client: SessionClient(
            displayName: current?.client.displayName ?? 'Giulia Rossi',
            contactPhone: current?.client.contactPhone,
            zone: current?.client.zone,
            status: current?.client.status,
          ),
          request: current,
        );
      }
    }
    return QuoteDraft(
      dryRun: false,
      quoteId: quoteId,
      requestId: request.requestId,
      clientId: current?.clientId ?? testClientId,
      holdUntil: hold,
      weeks: [
        for (final week in weeks)
          BookingWeek(
            date: week.date,
            start: week.start,
            cookMinutes: week.cookMinutes,
            status: BookingDayStatus.ok,
            serviceCents: week.serviceCents,
            sessionId: week.id,
          ),
      ],
    );
  }

  /// Lo que hace la base al confirmar sin presupuesto un pedido que tiene uno
  /// abierto (borrador o mandado): lo retira y cancela sus semanas retenidas.
  void withdrawOpen(String requestId) {
    final stored = quotes[requestId];
    if (stored == null || !stored.isOpen) return;
    final quote = _withSessionsOfNow(stored);
    final at = now().toUtc();
    quotes[requestId] = quote.copyWith(
      withdrawnAt: at,
      sessions: [
        for (final week in quote.sessions)
          week.status == SessionStatus.held
              ? week.copyWith(status: SessionStatus.cancelled)
              : week,
      ],
    );
    final server = sessions;
    if (server == null) return;
    for (final week in quote.sessions) {
      final session = server.sessions[week.id];
      if (session != null && session.status == SessionStatus.held) {
        server.sessions[week.id] = session.copyWith(
          status: SessionStatus.cancelled,
          cancelledAt: at,
          cancelReason: 'quote_withdrawn',
        );
      }
    }
  }

  RequestQuote? _byId(String quoteId) =>
      quotes.values.where((quote) => quote.id == quoteId).firstOrNull;

  @override
  Future<QuoteTerms> changePrice({
    required String quoteId,
    required int serviceTotalCents,
  }) async {
    priceCalls.add((quoteId: quoteId, cents: serviceTotalCents));
    QuoteFailure? refused = priceFailure;
    QuoteTerms? terms;
    final stored = _byId(quoteId);
    if (refused == null && stored == null) {
      refused = const QuoteFailure(QuoteFailureKind.notFound);
    }
    if (refused == null && stored != null) {
      final quote = _withSessionsOfNow(stored);
      final live = quote.liveSessions;
      if (!quote.isOpen) {
        refused = const QuoteFailure(QuoteFailureKind.closed);
      } else if (live.isEmpty) {
        refused = const QuoteFailure(QuoteFailureKind.empty);
      } else {
        final split = splitServiceCents(serviceTotalCents, live.length);
        final cents = {for (final (i, week) in live.indexed) week.id: split[i]};
        final updated = quote.copyWith(
          serviceCents: serviceTotalCents,
          sessions: [
            for (final week in quote.sessions)
              cents.containsKey(week.id)
                  ? week.copyWith(serviceCents: cents[week.id]!)
                  : week,
          ],
        );
        quotes[updated.requestId] = updated;
        final server = sessions;
        if (server != null) {
          for (final MapEntry(key: id, value: value) in cents.entries) {
            final session = server.sessions[id];
            if (session != null) {
              server.sessions[id] = session.copyWith(serviceCents: value);
            }
          }
        }
        terms = updated.currentTerms;
      }
    }
    final pending = pendingPrice;
    if (pending != null) await pending.future;
    if (refused != null) throw refused;
    return terms!;
  }

  @override
  Future<WithdrawnQuote> withdraw(String quoteId) async {
    withdrawCalls.add(quoteId);
    QuoteFailure? refused = withdrawFailure;
    WithdrawnQuote? result;
    final stored = _byId(quoteId);
    if (refused == null && stored == null) {
      refused = const QuoteFailure(QuoteFailureKind.notFound);
    }
    if (refused == null && stored != null) {
      final quote = _withSessionsOfNow(stored);
      if (quote.withdrawnAt != null) {
        result = (
          quoteId: quote.id,
          requestId: quote.requestId,
          already: true,
          cancelled: 0,
        );
      } else if (!quote.isOpen) {
        refused = const QuoteFailure(QuoteFailureKind.closed);
      } else {
        final at = now().toUtc();
        final held = [
          for (final week in quote.sessions)
            if (week.status == SessionStatus.held) week.id,
        ];
        quotes[quote.requestId] = quote.copyWith(
          withdrawnAt: at,
          sessions: [
            for (final week in quote.sessions)
              held.contains(week.id)
                  ? week.copyWith(status: SessionStatus.cancelled)
                  : week,
          ],
        );
        final server = sessions;
        if (server != null) {
          for (final id in held) {
            final session = server.sessions[id];
            if (session != null) {
              server.sessions[id] = session.copyWith(
                status: SessionStatus.cancelled,
                cancelledAt: at,
                cancelReason: 'quote_withdrawn',
              );
            }
          }
        }
        final requestServer = requests;
        final request = requestServer?.requests[quote.requestId];
        if (requestServer != null &&
            request != null &&
            request.status == RequestStatus.quoted) {
          requestServer.requests[request.id] = request.copyWith(
            status: RequestStatus.newRequest,
          );
        }
        result = (
          quoteId: quote.id,
          requestId: quote.requestId,
          already: false,
          cancelled: held.length,
        );
      }
    }
    final pending = pendingWithdraw;
    if (pending != null) await pending.future;
    if (refused != null) throw refused;
    return result!;
  }
}

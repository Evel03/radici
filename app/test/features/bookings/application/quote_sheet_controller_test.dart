// «Preparar presupuesto» sin widgets: la hoja de «Confirmar reserva» desde un
// pedido nuevo, con el dryRun y la creación en POST chef/quotes (nunca en
// chef/bookings): lo que se prellena, el precio de todo el presupuesto, lo
// que impide crearlo, el presupuesto creado y, si la creación se quedó sin
// respuesta, el reintento que encuentra el que ya se había creado.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/bookings/application/booking_seed.dart';
import 'package:radici/features/bookings/application/confirm_booking_controller.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/quotes/application/quote_providers.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/quote_fakes.dart';
import '../../../support/quote_fixtures.dart';
import '../../../support/request_fixtures.dart';

void main() {
  final monday = CalendarDate(2026, 11, 23);
  final mondays = weeklyDates(monday, 4);
  const source = BookingSource.quote('req-1');

  late FakeChefRequestsRepository requests;
  late FakeBookingsRepository bookings;
  late FakeSessionsRepository sessions;
  late FakeQuotesRepository quotes;
  late ProviderContainer container;

  ChefRequest weekly({
    int weeks = 4,
    RequestEstimate? estimate = fourWeeksEstimate,
    RequestStatus status = RequestStatus.newRequest,
    RequestType type = RequestType.week,
  }) => buildRequest(
    weeks: weeks,
    preferredDate: monday,
    estimate: estimate,
    status: status,
    type: type,
    seenAt: testNow,
  );

  Future<void> open(ChefRequest request) async {
    requests.requests[request.id] = request;
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
        bookingsRepositoryProvider.overrideWithValue(bookings),
        sessionsRepositoryProvider.overrideWithValue(sessions),
        quotesRepositoryProvider.overrideWithValue(quotes),
        clockProvider.overrideWithValue(() => testNow),
        newIdProvider.overrideWithValue(() => 'key-1'),
      ],
    );
    container
      ..listen(chefInboxProvider, (_, _) {})
      ..listen(chefRequestProvider(request.id), (_, _) {})
      ..listen(requestQuoteProvider(request.id), (_, _) {});
    await container.read(chefRequestProvider(request.id).future);
    container.listen(confirmBookingProvider(source), (_, _) {});
    await pumpEventQueue();
  }

  ConfirmBookingState state() => container.read(confirmBookingProvider(source));
  ConfirmBookingController controller() =>
      container.read(confirmBookingProvider(source).notifier);

  setUp(() {
    requests = FakeChefRequestsRepository(const []);
    bookings = FakeBookingsRepository(requests: requests);
    sessions = FakeSessionsRepository();
    quotes = FakeQuotesRepository(requests: requests, sessions: sessions);
  });

  test('se prellena como «Confirmar reserva» y el dryRun va a chef/quotes, nunca a chef/bookings', () async {
    await open(weekly());

    expect(state().isQuote, isTrue);
    expect(state().createsRequest, isFalse);
    expect(state().dates, mondays);
    expect(state().cookMinutes, 180);
    // El precio de la estimación: el de todo el presupuesto.
    expect(state().serviceTotalCents, 56000);
    expect(state().start, const ClockTime.hm(10, 0));
    final dryRun = quotes.dryRuns.single;
    expect(dryRun.requestId, 'req-1');
    expect(dryRun.dates, mondays);
    expect(dryRun.start, isNull);
    expect(dryRun.serviceTotalCents, isNull);
    expect(bookings.calls, isEmpty);
    expect(state().canConfirm, isTrue);
  });

  test('los avisos de cada fecha como en la reserva: solo un choque impide crearlo', () async {
    quotes.statuses[mondays[1]] = BookingDayStatus.blocked;
    await open(weekly());
    expect(state().checkFor(1)!.status, BookingDayStatus.blocked);
    expect(state().canConfirm, isTrue);

    quotes.statuses[mondays[2]] = BookingDayStatus.busy;
    controller().retryChecks();
    await pumpEventQueue();
    expect(state().hasClash, isTrue);
    expect(state().canConfirm, isFalse);
    expect(state().blocker, (kind: BookingBlockKind.clash, week: 2));
  });

  test('crear: el presupuesto con sus semanas retenidas, lo mismo que la reserva y sin clave', () async {
    await open(weekly());
    controller().setPriceText('500');
    await controller().confirm();

    final created = quotes.creations.single;
    expect(created.requestId, 'req-1');
    expect(created.dates, mondays);
    expect(created.start, const ClockTime.hm(10, 0));
    expect(created.cookMinutes, 180);
    expect(created.portions, 20);
    expect(created.serviceTotalCents, 50000);
    expect(created.toBody().containsKey('requestKey'), isFalse);
    expect(bookings.calls, isEmpty);

    final quote = state().quote!;
    expect(quote.quoteId, 'quote-1');
    expect(quote.firstSessionId, 'quote-1-1');
    expect(state().result!.weeks.map((w) => w.serviceCents), [
      12500,
      12500,
      12500,
      12500,
    ]);
    // Las semanas quedaron retenidas (held), sin confirmar, y el pedido
    // sigue nuevo: sale al mandarlo con el menú de la semana 1.
    expect(sessions.sessions.values.map((s) => s.status).toSet(), {
      SessionStatus.held,
    });
    expect(requests.requests['req-1']!.status, RequestStatus.newRequest);
    // El detalle del pedido vuelve a leer su presupuesto: ya tiene uno.
    final read = await container.read(requestQuoteProvider('req-1').future);
    expect(read!.id, 'quote-1');
  });

  test('el reparto que muestra la hoja es el de la base: los centavos que sobran, a las primeras', () async {
    await open(weekly(weeks: 3, estimate: null));
    controller().setPriceText('500');
    expect(state().serviceTotalCents, 50000);
    expect(splitServiceCents(state().serviceTotalCents!, state().weeks), [
      16667,
      16667,
      16666,
    ]);
    await controller().confirm();
    expect(quotes.creations.single.serviceTotalCents, 50000);
    expect(state().result!.weeks.map((w) => w.serviceCents), [
      16667,
      16667,
      16666,
    ]);
  });

  test(
    'un pedido de cambios o que ya no está nuevo: ni se pregunta al servidor',
    () async {
      await open(weekly(type: RequestType.change));
      expect(state().failure!.kind, BookingFailureKind.requestNotQuotable);
      expect(state().blocked, isTrue);
      expect(quotes.calls, isEmpty);
    },
  );

  test('ya tiene un presupuesto abierto (lo armó otro teléfono): la hoja no crea nada', () async {
    quotes.checksFailure = const BookingFailure(BookingFailureKind.quoteExists);
    await open(weekly());
    expect(state().failure!.kind, BookingFailureKind.quoteExists);
    expect(state().blocked, isTrue);
    expect(state().canConfirm, isFalse);
  });

  test('la creación se quedó sin respuesta: el reintento encuentra el presupuesto que ya se había creado', () async {
    await open(weekly());
    quotes.loseNextCreateResponse = true;
    await controller().confirm();
    expect(state().failure!.kind, BookingFailureKind.unavailable);
    expect(state().retryPending, isTrue);
    // Mientras tanto, nada cambia.
    controller().setPriceText('1');
    expect(state().priceEdited, isFalse);

    await controller().confirm();

    // El segundo intento manda lo mismo; la base dice quoteExists y la hoja
    // reconoce el suyo: un borrador con sus fechas, su hora y su precio.
    expect(quotes.creations, hasLength(2));
    expect(quotes.creations.last, quotes.creations.first);
    expect(state().failure, isNull);
    expect(state().result!.duplicate, isTrue);
    expect(state().quote!.quoteId, 'quote-1');
    expect(state().quote!.firstSessionId, 'quote-1-1');
  });

  test('si el que encuentra es otro (otro precio u otras fechas), no lo toma: quoteExists', () async {
    await open(weekly());
    quotes.loseNextCreateResponse = true;
    await controller().confirm();
    // Otro teléfono lo cambió en el medio.
    final stored = quotes.quotes['req-1']!;
    quotes.quotes['req-1'] = stored.copyWith(
      sessions: [
        for (final week in stored.sessions)
          week.copyWith(serviceCents: week.serviceCents + 1),
      ],
    );
    for (final id in sessions.sessions.keys.toList()) {
      final session = sessions.sessions[id]!;
      sessions.sessions[id] = session.copyWith(
        serviceCents: session.serviceCents + 1,
      );
    }

    await controller().confirm();

    expect(state().failure!.kind, BookingFailureKind.quoteExists);
    expect(state().blocked, isTrue);
    expect(state().result, isNull);
  });

  test(
    'un choque al crearlo: no se creó nada y el dryRun marca la semana',
    () async {
      await open(weekly());
      quotes.statuses[mondays[3]] = BookingDayStatus.busy;
      await controller().confirm();
      expect(state().failure!.kind, BookingFailureKind.slotTaken);
      expect(state().failure!.date, mondays[3]);
      await pumpEventQueue();
      expect(state().checkFor(3)!.status, BookingDayStatus.busy);
      expect(quotes.quotes, isEmpty);
    },
  );

  group('«Confirmar sin presupuesto» con uno abierto (la base lo retira al confirmar)', () {
    const booking = BookingSource.request('req-1');

    Future<ConfirmBookingState> openBooking(ChefRequest request) async {
      await open(request);
      container.listen(confirmBookingProvider(booking), (_, _) {});
      await pumpEventQueue();
      return container.read(confirmBookingProvider(booking));
    }

    test('con uno mandado (el pedido en «Presupuesto enviado»): la hoja se puede confirmar y avisa que lo retira', () async {
      quotes.quotes['req-1'] = buildQuote(sent: true);
      final sheet = await openBooking(weekly(status: RequestStatus.quoted));
      expect(sheet.failure, isNull);
      expect(sheet.quoteToWithdraw, QuoteToWithdraw.sent);
      expect(sheet.canConfirm, isTrue);
    });

    test('con un borrador: avisa que retira el borrador', () async {
      quotes.quotes['req-1'] = buildQuote();
      final sheet = await openBooking(weekly());
      expect(sheet.quoteToWithdraw, QuoteToWithdraw.draft);
    });

    test('sin uno abierto (o con uno cerrado), nada que avisar', () async {
      final sheet = await openBooking(weekly());
      expect(sheet.quoteToWithdraw, isNull);
      quotes.quotes['req-1'] = buildQuote(withdrawnAt: testNow);
      container.invalidate(requestQuoteProvider('req-1'));
      container.invalidate(confirmBookingProvider(booking));
      await pumpEventQueue();
      expect(
        container.read(confirmBookingProvider(booking)).quoteToWithdraw,
        isNull,
      );
    });

    test('si el presupuesto no se puede leer: lo dice el pedido (uno con el presupuesto mandado tiene uno abierto)', () async {
      quotes.fetchFailure = const QuoteFailure(QuoteFailureKind.unavailable);
      final quoted = await openBooking(weekly(status: RequestStatus.quoted));
      expect(quoted.quoteToWithdraw, QuoteToWithdraw.sent);
    });

    test('al confirmar, el pedido es una reserva y el presupuesto se vuelve a leer, retirado', () async {
      bookings = FakeBookingsRepository(
        requests: requests,
        onBookedFromRequest: quotes.withdrawOpen,
      );
      quotes.quotes['req-1'] = buildQuote(sent: true);
      await openBooking(weekly(status: RequestStatus.quoted));
      await container.read(confirmBookingProvider(booking).notifier).confirm();
      await pumpEventQueue();

      expect(bookings.confirmations, hasLength(1));
      expect(requests.requests['req-1']!.status, RequestStatus.accepted);
      final quote = await container.read(requestQuoteProvider('req-1').future);
      expect(quote!.withdrawnAt, isNotNull);
    });
  });
}

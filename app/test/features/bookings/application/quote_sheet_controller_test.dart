// «Preparar presupuesto» sin widgets: la hoja de «Confirmar reserva» desde un
// pedido nuevo, con el dryRun y la creación en POST chef/quotes (nunca en
// chef/bookings): lo que se prellena, el precio de todo el presupuesto, lo
// que impide crearlo, el presupuesto creado y, si la creación se quedó sin
// respuesta, el reintento que encuentra el que ya se había creado. Un
// presupuesto no nace vencido: la primera fecha empieza mañana y una primera
// llegada que ya pasó (a la hora de tocar «Crear») no deja crearlo. El
// presupuesto del pedido sigue al pedido (otro teléfono lo mandó, la clienta
// lo rechazó) y se vuelve a leer aunque la hoja ya no esté. «Confirmar sin
// presupuesto» con uno abierto avisa que lo retira, y «Rinnova» de esa reserva
// no cuenta las semanas del presupuesto retirado.
import 'dart:async';

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
import '../../../support/session_fixtures.dart';

void main() {
  final monday = CalendarDate(2026, 11, 23);
  final mondays = weeklyDates(monday, 4);
  const source = BookingSource.quote('req-1');

  late FakeChefRequestsRepository requests;
  late FakeBookingsRepository bookings;
  late FakeSessionsRepository sessions;
  late FakeQuotesRepository quotes;
  late ProviderContainer container;

  /// "Ahora": por defecto, lunes 19/10/2026 a las 14:00 en Roma.
  late DateTime now;

  /// La hoja abierta (cerrarla es como sacarla de la pantalla).
  late ProviderSubscription<ConfirmBookingState> sheet;

  ChefRequest weekly({
    int weeks = 4,
    RequestEstimate? estimate = fourWeeksEstimate,
    RequestStatus status = RequestStatus.newRequest,
    RequestType type = RequestType.week,
    CalendarDate? preferredDate,
  }) => buildRequest(
    weeks: weeks,
    preferredDate: preferredDate ?? monday,
    estimate: estimate,
    status: status,
    type: type,
    seenAt: testNow,
  );

  /// Abre la hoja del presupuesto de [request], con la bandeja y el
  /// presupuesto del pedido leídos. [beforeSheet] cambia "el servidor" justo
  /// antes de abrirla (lo que hizo otro teléfono o la clienta mientras tanto).
  Future<void> open(ChefRequest request, {void Function()? beforeSheet}) async {
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
        clockProvider.overrideWithValue(() => now),
        newIdProvider.overrideWithValue(() => 'key-1'),
      ],
    );
    container
      ..listen(chefInboxProvider, (_, _) {})
      ..listen(chefRequestProvider(request.id), (_, _) {})
      ..listen(requestQuoteProvider(request.id), (_, _) {});
    await container.read(chefRequestProvider(request.id).future);
    if (beforeSheet != null) {
      await container.read(requestQuoteProvider(request.id).future);
      beforeSheet();
    }
    sheet = container.listen(confirmBookingProvider(source), (_, _) {});
    await pumpEventQueue();
  }

  ConfirmBookingState state() => container.read(confirmBookingProvider(source));
  ConfirmBookingController controller() =>
      container.read(confirmBookingProvider(source).notifier);

  setUp(() {
    now = testNow;
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

  group('la primera llegada ya pasó: un presupuesto nace vencido (solo en el presupuesto)', () {
    // "Ahora": lunes 19/10/2026 a las 14:00 en Roma.
    final today = CalendarDate(2026, 10, 19);

    test('una fecha preferida que ya pasó (un pedido atendido tarde) o la de hoy: empieza mañana', () async {
      await open(weekly(preferredDate: CalendarDate(2026, 10, 12)));
      expect(state().dates.first, today.addDays(1));
      expect(state().dates, weeklyDates(today.addDays(1), 4));
      expect(state().canConfirm, isTrue);
    });

    test('la preferida de hoy también empieza mañana', () async {
      await open(weekly(preferredDate: today));
      expect(state().dates.first, today.addDays(1));
    });

    test('una primera semana pasada, elegida a mano: no se crea, y la barra dice por qué', () async {
      await open(weekly());
      controller().setDate(0, CalendarDate(2026, 10, 12));
      await pumpEventQueue();
      expect(state().checksCurrent, isTrue);
      expect(state().canConfirm, isFalse);
      expect(state().blocker, (kind: BookingBlockKind.arrival, week: 0));

      await controller().confirm();
      expect(quotes.creations, isEmpty);
    });

    test(
      'hoy, con la llegada que ya pasó: tampoco; con una llegada más tarde, sí',
      () async {
        await open(weekly());
        controller().setDate(0, today);
        await pumpEventQueue();
        // La llegada sugerida, las 10:00, ya pasó (son las 14:00).
        expect(state().start, const ClockTime.hm(10, 0));
        expect(state().canConfirm, isFalse);
        expect(state().blocker, (kind: BookingBlockKind.arrival, week: 0));

        controller().setStart(const ClockTime.hm(15, 0));
        await pumpEventQueue();
        expect(state().blocker, isNull);
        expect(state().canConfirm, isTrue);
      },
    );

    test(
      'mira la hora al tocar «Crear», no la de cuando se abrió la hoja',
      () async {
        await open(weekly());
        controller()
          ..setDate(0, today)
          ..setStart(const ClockTime.hm(14, 30));
        await pumpEventQueue();
        expect(state().canConfirm, isTrue);

        // Pasaron 40 minutos con la hoja abierta: las 14:30 ya pasaron.
        now = now.add(const Duration(minutes: 40));
        await controller().confirm();
        expect(quotes.creations, isEmpty);
        expect(state().canConfirm, isFalse);
        expect(state().blocker, (kind: BookingBlockKind.arrival, week: 0));
      },
    );

    test('la reserva desde el pedido sigue aceptando fechas pasadas (lo hecho en Fase 0)', () async {
      const booking = BookingSource.request('req-1');
      await open(weekly(preferredDate: CalendarDate(2026, 10, 12)));
      container.listen(confirmBookingProvider(booking), (_, _) {});
      await pumpEventQueue();
      final sheet = container.read(confirmBookingProvider(booking));
      expect(sheet.dates.first, CalendarDate(2026, 10, 12));
      expect(sheet.blocker, isNull);
      expect(sheet.canConfirm, isTrue);
    });
  });

  group('el presupuesto del pedido sigue al pedido', () {
    test('otro teléfono lo mandó mientras tanto (requestNotNew, quoted): el pedido y su presupuesto se vuelven a leer', () async {
      await open(
        weekly(),
        beforeSheet: () {
          requests.requests['req-1'] = weekly(status: RequestStatus.quoted);
          quotes.quotes['req-1'] = buildQuote(sent: true);
        },
      );

      expect(state().failure!.kind, BookingFailureKind.requestNotNew);
      final local = container
          .read(chefInboxProvider)
          .value!
          .singleWhere((r) => r.id == 'req-1');
      expect(local.status, RequestStatus.quoted);
      final quote = container.read(requestQuoteProvider('req-1')).value;
      expect(quote?.id, testQuoteId);
      expect(quote!.wasSent, isTrue);
    });

    test('si la hoja se cierra mientras lo crea, el pedido igual vuelve a leer su presupuesto al crearse', () async {
      await open(weekly());
      final reads = quotes.fetches.length;
      quotes.pendingCreate = Completer<void>();
      final creating = controller().confirm();
      // El atrás del navegador saca la hoja mientras espera.
      sheet.close();
      await pumpEventQueue();
      quotes.pendingCreate!.complete();
      await creating;
      await pumpEventQueue();

      expect(quotes.creations, hasLength(1));
      expect(quotes.fetches.length, greaterThan(reads));
      final quote = container.read(requestQuoteProvider('req-1')).value;
      expect(quote?.id, 'quote-1');
    });
  });

  group('«Confirmar sin presupuesto» con uno abierto (la base lo retira al confirmar)', () {
    const booking = BookingSource.request('req-1');

    Future<ConfirmBookingState> openBooking(
      ChefRequest request, {
      void Function()? beforeSheet,
    }) async {
      await open(request, beforeSheet: beforeSheet);
      container.listen(confirmBookingProvider(booking), (_, _) {});
      await pumpEventQueue();
      return container.read(confirmBookingProvider(booking));
    }

    test('la clienta lo rechazó mientras tanto (requestNotNew, declined): el presupuesto del pedido se vuelve a leer, rechazado', () async {
      quotes.quotes['req-1'] = buildQuote(sent: true);
      final sheet = await openBooking(
        weekly(status: RequestStatus.quoted),
        beforeSheet: () {
          requests.requests['req-1'] = weekly(status: RequestStatus.declined);
          quotes.quotes['req-1'] = buildQuote(
            sent: true,
            declinedAt: DateTime.utc(2026, 10, 19, 11),
          );
        },
      );

      expect(sheet.failure!.kind, BookingFailureKind.requestNotNew);
      final quote = container.read(requestQuoteProvider('req-1')).value;
      expect(quote!.declinedAt, isNotNull);
      expect(quote.isOpen, isFalse);
    });

    test('un pedido «Presupuesto enviado» sin presupuesto leído (dato viejo): avisa igual que retira el mandado', () async {
      final sheet = await openBooking(weekly(status: RequestStatus.quoted));
      expect(sheet.quoteToWithdraw, QuoteToWithdraw.sent);
    });

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

    test('«Rinnova» de esa reserva: sus 4 semanas y su precio, sin las semanas del presupuesto retirado', () async {
      bookings = FakeBookingsRepository(
        requests: requests,
        sessions: sessions,
        onBookedFromRequest: quotes.withdrawOpen,
      );
      // El presupuesto mandado, con sus 4 semanas retenidas de 140 €.
      final sent = buildQuote(sent: true);
      quotes.quotes['req-1'] = sent;
      for (final week in sent.sessions) {
        sessions.sessions[week.id] = buildSession(
          id: week.id,
          date: week.date,
          start: week.start,
          serviceCents: week.serviceCents,
          status: SessionStatus.held,
          requestId: 'req-1',
          requestStatus: RequestStatus.quoted,
        );
      }
      await openBooking(weekly(status: RequestStatus.quoted));
      await container.read(confirmBookingProvider(booking).notifier).confirm();
      await pumpEventQueue();

      // Las 4 retenidas, canceladas al retirarlo; las 4 de la reserva,
      // confirmadas.
      final ofRequest = sessions.sessions.values.where(
        (s) => s.requestId == 'req-1',
      );
      expect(
        ofRequest.where((s) => s.cancelReason == 'quote_withdrawn'),
        hasLength(4),
      );
      final confirmed = [
        for (final s in ofRequest)
          if (s.status == SessionStatus.confirmed) s,
      ]..sort((a, b) => a.date.compareTo(b.date));
      expect(confirmed, hasLength(4));

      final renewal = BookingSource.renewal(confirmed.last.id);
      container.listen(confirmBookingProvider(renewal), (_, _) {});
      await pumpEventQueue();
      final sheet = container.read(confirmBookingProvider(renewal));
      expect(sheet.seedStatus, BookingSeedStatus.ready);
      expect(sheet.weeks, 4);
      expect(sheet.serviceTotalCents, 56000);
    });
  });
}

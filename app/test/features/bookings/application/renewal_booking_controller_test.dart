// La hoja «Rinnova prenotazione», sin widgets: espera la reserva de la sesión
// (sin pasar por «no está»), la arma con lo que copia «Rinnova» (semanas,
// fechas desde la última viva + 7, hora, minutos, precio, hogar e idioma), el
// primer dryRun ya lleva la hora, confirma con clientId (el cuerpo 4 de la
// especificación) y deja la reserva marcada como renovada aunque las
// sesiones no se puedan volver a leer. El precio de otra cantidad de semanas
// sale de las tarifas de la estimación o queda vacío; los avisos de la app;
// el hogar no mueve los minutos; la respuesta perdida se reintenta con la
// misma clave. "Hoy": lunes 19/10/2026 a las 14:00 en Roma, salvo donde se
// dice otra cosa.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/features/bookings/application/booking_message.dart';
import 'package:radici/features/bookings/application/booking_seed.dart';
import 'package:radici/features/bookings/application/confirm_booking_controller.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/clients/data/clients_repository.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';
import 'package:radici/features/sessions/application/renewed_bookings.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  // La reserva de prueba: miércoles 25/11, 2/12, 9/12 y 16/12 a las 10:00,
  // 180 min, 4 × 140 €. Se renueva desde su última semana.
  final source = BookingSource.renewal(sessionId(4));
  final renewalDates = weeklyDates(CalendarDate(2026, 12, 23), 4);
  final dryRunBody = {
    'clientId': testClientId,
    'type': 'week',
    'household': {
      'adults': 2,
      'kids': 2,
      'days': 5,
      'meals': ['dinner'],
    },
    'locale': 'it',
    'dates': [for (final date in renewalDates) date.toIso()],
    'start': '10:00',
    'cookMinutes': 180,
    'portions': 20,
    'groceriesEstCents': 6300,
    'dryRun': true,
  };

  late DateTime now;
  late FakeChefRequestsRepository requests;
  late FakeBookingsRepository bookings;
  late FakeSessionsRepository sessions;
  late ProviderContainer container;
  late int keys;

  setUpAll(initializeDateFormatting);

  setUp(() async {
    keys = 0;
    now = testNow;
    requests = FakeChefRequestsRepository(const []);
    final clients = FakeClientsRepository();
    bookings = FakeBookingsRepository(requests: requests, clients: clients);
    sessions = FakeSessionsRepository();
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
        clientsRepositoryProvider.overrideWithValue(clients),
        bookingsRepositoryProvider.overrideWithValue(bookings),
        sessionsRepositoryProvider.overrideWithValue(sessions),
        clockProvider.overrideWithValue(() => now),
        newIdProvider.overrideWithValue(() => 'key-${++keys}'),
      ],
    );
    container
      ..listen(currentChefProvider, (_, _) {})
      ..listen(chefInboxProvider, (_, _) {});
    await pumpEventQueue();
  });

  void save(List<CookingSession> booking) {
    for (final session in booking) {
      sessions.sessions[session.id] = session;
    }
  }

  Future<void> open([BookingSource? from]) async {
    container.listen(confirmBookingProvider(from ?? source), (_, _) {});
    await pumpEventQueue();
  }

  ConfirmBookingState state([BookingSource? from]) =>
      container.read(confirmBookingProvider(from ?? source));
  ConfirmBookingController controller() =>
      container.read(confirmBookingProvider(source).notifier);

  group('antes de la hoja', () {
    test('escuchada antes de que llegue la reserva: de «cargando» a «lista», sin pasar por «no está»', () async {
      save(buildBooking());
      sessions.pendingFetch = Completer<void>();
      await open();
      expect(state().seedStatus, BookingSeedStatus.loading);
      expect(state().kind, BookingSourceKind.renewal);
      expect(state().canConfirm, isFalse);
      expect(bookings.calls, isEmpty);

      sessions.pendingFetch!.complete();
      await pumpEventQueue();
      expect(state().seedStatus, BookingSeedStatus.ready);
      expect(bookings.dryRuns, hasLength(1));
    });

    test('una sesión que no existe, o que no se puede renovar: «no está», sin preguntarle al servidor', () async {
      await open();
      expect(state().seedStatus, BookingSeedStatus.missing);
      final extra = BookingSource.renewal(sessionId(5));
      save([buildSession(n: 5, requestId: 'extra', type: RequestType.extra)]);
      await open(extra);
      expect(state(extra).seedStatus, BookingSeedStatus.missing);
      expect(bookings.calls, isEmpty);
    });

    test('si la reserva no se pudo leer: «error», y lo que llega al reintentar se toma', () async {
      save(buildBooking());
      sessions.fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
      await open();
      expect(state().seedStatus, BookingSeedStatus.error);

      sessions.fetchFailure = null;
      container.invalidate(sessionDetailProvider(sessionId(4)));
      await pumpEventQueue();
      expect(state().seedStatus, BookingSeedStatus.ready);
      expect(state().dates, renewalDates);
    });
  });

  group('la hoja armada', () {
    test('lo que copia «Rinnova» y el primer dryRun ya con la hora (el cuerpo 4)', () async {
      save(buildBooking());
      await open();
      expect(bookings.dryRuns.first.toBody(), dryRunBody);
      expect(state().kind, BookingSourceKind.renewal);
      expect(state().createsRequest, isTrue);
      expect(state().isManual, isFalse);
      expect(state().dates, renewalDates);
      expect(state().maxWeeks, 8);
      expect(state().start, const ClockTime.hm(10, 0));
      expect(state().startEdited, isTrue);
      expect(state().cookMinutes, 180);
      expect(state().suggestedPriceCents, 56000);
      expect(state().serviceTotalCents, 56000);
      expect(state().priceIssue, isNull);
      expect(
        state().household,
        const BookingHousehold(adults: 2, kids: 2, days: 5, meals: [Meal.dinner]),
      );
      expect(state().locale, ClientLocale.it);
      expect(state().renewedFrom, CalendarDate(2026, 12, 16));
      expect(state().canConfirm, isTrue, reason: 'el precio ya está');
    });

    test('el encabezado: el nombre de la ficha, la semana movida y el teléfono del pedido si es otro', () async {
      final booking = [
        for (final session in buildBooking())
          session.copyWith(
            request: session.request!.copyWith(
              client: session.request!.client.copyWith(
                displayName: 'Giuly Bianchi',
                contactPhone: '+34 612 345 678',
              ),
            ),
          ),
      ];
      booking[3] = booking[3].copyWith(
        date: CalendarDate(2026, 12, 18),
        start: const ClockTime.hm(11, 0),
      );
      save(booking);
      await open();
      expect(state().party?.displayName, 'Giulia Rossi');
      expect(state().party?.phoneE164, '+393331234567');
      expect(state().lastMoved, isTrue);
      expect(state().otherRequestPhone, '+34 612 345 678');
      expect(state().dates.first, CalendarDate(2026, 12, 25));
      expect(bookings.dryRuns.first.start, const ClockTime.hm(11, 0));
    });

    test('confirmar sin tocar nada manda el cuerpo 4 con 560 € y la clave de la hoja; el WhatsApp va a la ficha', () async {
      save(buildBooking());
      await open();
      await controller().confirm();
      expect(bookings.confirmations.single.toBody(), {
        ...dryRunBody,
        'serviceTotalCents': 56000,
        'requestKey': 'key-1',
        'dryRun': false,
      });
      expect(state().result?.weeks.first.date, CalendarDate(2026, 12, 23));
      final whatsApp = container.read(bookingWhatsAppProvider(source))!;
      expect(whatsApp.path, '/393331234567');
      expect(whatsApp.queryParameters['text'], startsWith('Ciao Giulia'));
    });
  });

  group('el precio al cambiar las semanas', () {
    test('con la estimación de la web (y 560 € en 4), 2 semanas proponen 300 €', () async {
      save(buildBooking(estimate: fourWeeksEstimate));
      await open();
      controller().setWeeks(2);
      expect(state().suggestedPriceCents, 30000);
      expect(state().serviceTotalCents, 30000);
      controller().setWeeks(4);
      expect(state().suggestedPriceCents, 56000);
    });

    test('sin la estimación de la web, 2 semanas dejan el precio vacío y obligatorio', () async {
      save(buildBooking());
      await open();
      controller().setWeeks(2);
      expect(state().suggestedPriceCents, isNull);
      expect(state().priceIssue, BookingPriceIssue.required);
      expect(state().blocker, (kind: BookingBlockKind.price, week: null));
    });
  });

  group('después de confirmar', () {
    test('la reserva queda marcada como renovada (la primera fecha guardada) aunque las sesiones no se puedan volver a leer', () async {
      save(buildBooking());
      container.listen(sessionsControllerProvider, (_, _) {});
      await pumpEventQueue();
      await open();
      final reads = sessions.fetchCalls;
      sessions.fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
      await controller().confirm();
      await pumpEventQueue();
      expect(sessions.fetchCalls, reads + 1, reason: 'intentó volver a leerlas');
      expect(container.read(renewedBookingsProvider), {
        bookingRequestId: CalendarDate(2026, 12, 23),
      });
    });

    test('el pedido de la renovación queda en «Prenotazioni» enseguida, con la ficha, aunque la relectura falle', () async {
      save(buildBooking());
      await open();
      requests.failFetch = true;
      await controller().confirm();
      await pumpEventQueue();
      final booked = container
          .read(chefInboxProvider)
          .requireValue
          .singleWhere((r) => r.id == 'manual-request-1');
      expect(booked.source, RequestSource.app);
      expect(booked.status, RequestStatus.accepted);
      expect(booked.clientId, testClientId);
      expect(booked.weeks, 4);
      expect(booked.client.displayName, 'Giulia Rossi');
      expect(booked.client.status, ClientStatus.trial);
      expect(inboxTabOf(booked), InboxTab.bookings);
    });

    test('respuesta perdida: el reintento manda lo mismo con la misma clave y, con duplicate, también marca la reserva', () async {
      save(buildBooking());
      await open();
      bookings.loseNextConfirmResponse = true;
      await controller().confirm();
      expect(state().retryPending, isTrue);
      expect(container.read(renewedBookingsProvider), isEmpty);

      await controller().confirm();
      final sent = bookings.confirmations;
      expect(sent, hasLength(2));
      expect(sent.last, sent.first);
      expect(sent.last.requestKey, 'key-1');
      expect(state().result?.duplicate, isTrue);
      expect(container.read(renewedBookingsProvider), {
        bookingRequestId: CalendarDate(2026, 12, 23),
      });
    });
  });

  group('avisos de la app (no impiden confirmar)', () {
    test('el 6/1 es feriado (Epifania)', () async {
      save(buildBooking());
      await open();
      expect(state().holidayFor(2), ItalianHoliday.epiphany);
      expect(state().holidayFor(0), isNull);
      expect(state().canConfirm, isTrue);
    });

    test('desde Hoy el día +7 a las 18:00: la semana 1 es hoy y su llegada ya pasó', () async {
      // Martes 20/10 a 10/11 a las 10:00; hoy, martes 17/11 a las 18:00.
      now = DateTime.utc(2026, 11, 17, 17);
      save(buildBooking(first: CalendarDate(2026, 10, 20)));
      await open();
      expect(state().dates.first, CalendarDate(2026, 11, 17));
      expect(state().arrivalPassed(0), isTrue);
      expect(state().arrivalPassed(1), isFalse);
      expect(state().canConfirm, isTrue);
    });
  });

  group('el hogar y los minutos', () {
    test('cambiar los adultos recalcula porciones y compra, pero no los minutos copiados', () async {
      save(buildBooking());
      await open();
      final dryRuns = bookings.dryRuns.length;
      controller().stepHousehold(HouseholdCounter.adults, 1);
      await pumpEventQueue();
      final estimate = manualBookingEstimate(
        const BookingHousehold(adults: 3, kids: 2, days: 5, meals: [Meal.dinner]),
      );
      expect(state().household?.adults, 3);
      expect(state().portions, estimate.portions);
      expect(state().groceriesEstCents, estimate.groceriesEstCents);
      expect(state().cookMinutes, 180);
      expect(bookings.dryRuns, hasLength(dryRuns));
    });

    test('más de 300 minutos se copian tal cual; «+» no los cambia y «−» los lleva a 300', () async {
      save([
        for (final session in buildBooking()) session.copyWith(cookMinutes: 360),
      ]);
      await open();
      expect(state().cookMinutes, 360);
      expect(bookings.dryRuns.first.cookMinutes, 360);
      controller().stepCookMinutes(1);
      expect(state().cookMinutes, 360);
      controller().stepCookMinutes(-1);
      expect(state().cookMinutes, 300);
    });
  });

  test('la ficha ya no existe (404): bloquea la hoja', () async {
    save(buildBooking());
    bookings.checksFailure = const BookingFailure(BookingFailureKind.notFound);
    await open();
    expect(state().failure?.kind, BookingFailureKind.notFound);
    expect(state().blocked, isTrue);
    expect(state().canConfirm, isFalse);
  });
}

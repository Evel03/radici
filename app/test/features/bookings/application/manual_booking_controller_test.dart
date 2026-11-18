// La hoja «Conferma prenotazione» a mano, sin widgets: espera su seed (sin
// pasar por «no está»), los cuerpos exactos para una ficha existente y una
// nueva, el hogar y el idioma (una sola fuente con el borrador en una ficha
// nueva), los avisos de la app (feriado y llegada de hoy pasada), las fallas
// (la ficha que ya no está, los datos de la ficha nueva rechazados) y la
// respuesta perdida, que se reintenta con la misma clave. "Hoy": lunes
// 19/10/2026 a las 14:00 en Roma.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/features/bookings/application/booking_seed.dart';
import 'package:radici/features/bookings/application/confirm_booking_controller.dart';
import 'package:radici/features/bookings/application/new_client_form_controller.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/clients/application/client_directory_controller.dart';
import 'package:radici/features/clients/data/clients_repository.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';

import '../../../support/client_fixtures.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  final today = CalendarDate(2026, 10, 19);
  final fourWeeks = weeklyDates(today.addDays(1), 4);
  const chiaraSource = BookingSource.client('c-chiara');
  const newSource = BookingSource.newClient();

  late FakeChefRequestsRepository requests;
  late FakeClientsRepository clients;
  late FakeBookingsRepository bookings;
  late FakeSessionsRepository sessions;
  late ProviderContainer container;
  late int keys;

  // Chiara: activa, con un último pedido semanal de 3 + 1, 4 días, almuerzo y
  // cena, en español.
  final chiara = buildClient(
    id: 'c-chiara',
    name: 'Chiara Rossi',
    phone: '340 111 2233',
    zone: 'Loreto',
    latestWeekly: buildLatestWeekly(
      locale: ClientLocale.es,
      adults: 3,
      kids: 1,
      days: 4,
      meals: const [Meal.lunch, Meal.dinner],
    ),
  );
  // Anna: un prospecto sin pedidos semanales (2 + 2 de la ficha).
  final anna = buildClient(
    id: 'c-anna',
    name: 'Anna Verdi',
    phone: null,
    zone: null,
    adults: 2,
    kids: 2,
    status: ClientStatus.prospect,
  );
  const chiaraHousehold = BookingHousehold(
    adults: 3,
    kids: 1,
    days: 4,
    meals: [Meal.lunch, Meal.dinner],
  );

  setUp(() async {
    keys = 0;
    requests = FakeChefRequestsRepository(const []);
    clients = FakeClientsRepository([chiara, anna]);
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
        clockProvider.overrideWithValue(() => testNow),
        newIdProvider.overrideWithValue(() => 'key-${++keys}'),
      ],
    );
    // Como en la app: la bandeja cargada y, mientras dure el flujo, el elegir
    // escucha el borrador y el directorio.
    container
      ..listen(currentChefProvider, (_, _) {})
      ..listen(chefInboxProvider, (_, _) {})
      ..listen(newClientFormProvider, (_, _) {})
      ..listen(clientDirectoryProvider, (_, _) {});
    await pumpEventQueue();
  });

  Future<void> open(BookingSource source) async {
    container.listen(confirmBookingProvider(source), (_, _) {});
    await pumpEventQueue();
  }

  ConfirmBookingState state([BookingSource source = chiaraSource]) =>
      container.read(confirmBookingProvider(source));
  ConfirmBookingController controller([BookingSource source = chiaraSource]) =>
      container.read(confirmBookingProvider(source).notifier);
  NewClientFormController form() =>
      container.read(newClientFormProvider.notifier);

  void fillNewClient() => form()
    ..setName('Giulia Rossi')
    ..setPhone('333 123 4567')
    ..setZone('Città Alta')
    ..setAddress('Via Gombito 12, Bergamo');

  group('el seed', () {
    test('escuchado antes de que llegue: de «cargando» a «lista», sin pasar por «no está»', () async {
      container.invalidate(clientDirectoryProvider);
      clients.pendingFetch = Completer<void>();
      container.listen(confirmBookingProvider(chiaraSource), (_, _) {});
      await pumpEventQueue();
      expect(state().seedStatus, BookingSeedStatus.loading);
      expect(state().failure, isNull);
      expect(state().canConfirm, isFalse);
      expect(bookings.calls, isEmpty);

      clients.pendingFetch!.complete();
      await pumpEventQueue();
      expect(state().seedStatus, BookingSeedStatus.ready);
      expect(state().kind, BookingSourceKind.manual);
      expect(state().party?.displayName, 'Chiara Rossi');
      expect(bookings.dryRuns, hasLength(1));
    });

    test('si el seed se recalcula (o pasa a null al descartar el borrador), la hoja no se rehace', () async {
      fillNewClient();
      await open(newSource);
      expect(state(newSource).seedStatus, BookingSeedStatus.ready);
      controller(newSource).setPriceText('140');

      form().setName('Otra');
      await pumpEventQueue();
      expect(state(newSource).party?.displayName, 'Giulia Rossi');
      container.invalidate(newClientFormProvider);
      await pumpEventQueue();
      expect(state(newSource).seedStatus, BookingSeedStatus.ready);
      expect(state(newSource).party?.displayName, 'Giulia Rossi');
      expect(state(newSource).priceText, '140');
    });

    test('un error del seed da «error» y el valor que llega al reintentar se toma como el primero', () async {
      container.invalidate(clientDirectoryProvider);
      clients.fetchFailure = const ClientsFailure(ClientsFailureKind.unavailable);
      await open(chiaraSource);
      expect(state().seedStatus, BookingSeedStatus.error);
      expect(state().canConfirm, isFalse);

      clients.fetchFailure = null;
      container.invalidate(clientDirectoryProvider);
      await pumpEventQueue();
      expect(state().seedStatus, BookingSeedStatus.ready);
      expect(state().dates, fourWeeks);
    });

    test('una ficha que no está: «no está», sin preguntarle al servidor', () async {
      await open(const BookingSource.client('nope'));
      expect(
        state(const BookingSource.client('nope')).seedStatus,
        BookingSeedStatus.missing,
      );
      expect(bookings.calls, isEmpty);
    });

    test('una ficha nueva sin borrador (la página se recargó): «no está»', () async {
      await open(newSource);
      expect(state(newSource).seedStatus, BookingSeedStatus.missing);
    });
  });

  group('una ficha existente', () {
    test('el primer dryRun va sin hora, con clientId, el hogar y el idioma de su último pedido semanal', () async {
      await open(chiaraSource);
      final estimate = manualBookingEstimate(chiaraHousehold);
      expect(bookings.dryRuns.first.toBody(), {
        'clientId': 'c-chiara',
        'type': 'week',
        'household': {
          'adults': 3,
          'kids': 1,
          'days': 4,
          'meals': ['lunch', 'dinner'],
        },
        'locale': 'es',
        'dates': [for (final date in fourWeeks) date.toIso()],
        'cookMinutes': estimate.cookMinutes,
        'portions': estimate.portions,
        'groceriesEstCents': estimate.groceriesEstCents,
        'dryRun': true,
      });
      expect(state().start, const ClockTime.hm(10, 0));
      expect(state().maxWeeks, 8);
      expect(state().household, chiaraHousehold);
      expect(state().locale, ClientLocale.es);
    });

    test('sin precio no deja confirmar; con «560» manda el cuerpo exacto con la clave de la hoja', () async {
      await open(chiaraSource);
      expect(state().blocker, (kind: BookingBlockKind.price, week: null));
      expect(state().canConfirm, isFalse);
      await controller().confirm();
      expect(bookings.confirmations, isEmpty);

      controller().setPriceText('560');
      expect(state().canConfirm, isTrue);
      await controller().confirm();
      final estimate = manualBookingEstimate(chiaraHousehold);
      expect(bookings.confirmations.single.toBody(), {
        'clientId': 'c-chiara',
        'type': 'week',
        'household': {
          'adults': 3,
          'kids': 1,
          'days': 4,
          'meals': ['lunch', 'dinner'],
        },
        'locale': 'es',
        'dates': [for (final date in fourWeeks) date.toIso()],
        'start': '10:00',
        'cookMinutes': estimate.cookMinutes,
        'portions': estimate.portions,
        'groceriesEstCents': estimate.groceriesEstCents,
        'serviceTotalCents': 56000,
        'requestKey': 'key-1',
        'dryRun': false,
      });
      expect(state().result?.requestId, 'manual-request-1');
    });

    test('la reserva queda en «Prenotazioni» enseguida y se reemplaza al releer el pedido', () async {
      await open(chiaraSource);
      controller().setPriceText('560');
      await controller().confirm();
      await pumpEventQueue();
      final inbox = container.read(chefInboxProvider).requireValue;
      final booked = inbox.singleWhere((r) => r.id == 'manual-request-1');
      expect(inboxTabOf(booked), InboxTab.bookings);
      expect(booked, requests.requests['manual-request-1'], reason: 'el pedido releído');
    });

    test('con la relectura fallando, el pedido provisorio queda en la bandeja', () async {
      await open(chiaraSource);
      controller().setPriceText('560');
      requests.failFetch = true;
      await controller().confirm();
      await pumpEventQueue();
      final booked = container
          .read(chefInboxProvider)
          .requireValue
          .singleWhere((r) => r.id == 'manual-request-1');
      expect(booked.status, RequestStatus.accepted);
      expect(booked.source, RequestSource.app);
      expect(booked.seenAt, isNotNull);
      expect(booked.isNew, isFalse);
      expect(booked.clientId, 'c-chiara');
      expect(booked.weeks, 4);
      expect(booked.adults, 3);
      expect(booked.meals, [Meal.lunch, Meal.dinner]);
      expect(booked.locale, ClientLocale.es);
      expect(booked.client.displayName, 'Chiara Rossi');
      expect(booked.client.contactPhone, '340 111 2233');
      expect(booked.client.zone, 'Loreto');
      expect(booked.client.status, ClientStatus.active);
      expect(inboxTabOf(booked), InboxTab.bookings);
    });

    test('un prospecto pasa a trial (también en sus otros pedidos de la bandeja)', () async {
      requests.requests['req-anna'] = buildRequest(
        id: 'req-anna',
        clientId: 'c-anna',
        name: 'Anna Verdi',
        clientStatus: ClientStatus.prospect,
      );
      await container.read(chefInboxProvider.notifier).refresh();
      const source = BookingSource.client('c-anna');
      await open(source);
      controller(source).setPriceText('200');
      requests.failFetch = true;
      await controller(source).confirm();
      await pumpEventQueue();
      final byId = {
        for (final r in container.read(chefInboxProvider).requireValue) r.id: r,
      };
      expect(byId['manual-request-1']!.client.status, ClientStatus.trial);
      expect(byId['req-anna']!.client.status, ClientStatus.trial);
    });

    test('con la agenda abierta, al confirmar vuelve a leer las sesiones', () async {
      container.listen(sessionsControllerProvider, (_, _) {});
      await pumpEventQueue();
      final reads = sessions.fetchCalls;
      await open(chiaraSource);
      controller().setPriceText('560');
      await controller().confirm();
      await pumpEventQueue();
      expect(sessions.fetchCalls, reads + 1);
    });

    test('confirmar descarta el borrador del flujo y no vuelve a leer el directorio', () async {
      form().setName('algo escrito');
      await open(chiaraSource);
      final reads = clients.fetchCalls;
      controller().setPriceText('560');
      await controller().confirm();
      await pumpEventQueue();
      expect(container.read(newClientFormProvider).isEmpty, isTrue);
      expect(clients.fetchCalls, reads);
    });
  });

  group('una ficha nueva', () {
    test('el dryRun y la confirmación llevan newClient completo', () async {
      fillNewClient();
      await open(newSource);
      final estimate = manualBookingEstimate(defaultManualHousehold);
      const newClientJson = {
        'name': 'Giulia Rossi',
        'phone': '+393331234567',
        'zone': 'Città Alta',
        'address': 'Via Gombito 12, Bergamo',
      };
      expect(bookings.dryRuns.first.toBody(), {
        'newClient': newClientJson,
        'type': 'week',
        'household': {
          'adults': 2,
          'kids': 2,
          'days': 5,
          'meals': ['dinner'],
        },
        'locale': 'it',
        'dates': [for (final date in fourWeeks) date.toIso()],
        'cookMinutes': estimate.cookMinutes,
        'portions': estimate.portions,
        'groceriesEstCents': estimate.groceriesEstCents,
        'dryRun': true,
      });

      controller(newSource).setPriceText('560');
      await controller(newSource).confirm();
      final sent = bookings.confirmations.single.toBody();
      expect(sent['newClient'], newClientJson);
      expect(sent['start'], '10:00');
      expect(sent['serviceTotalCents'], 56000);
      expect(sent['requestKey'], 'key-1');
      expect(state(newSource).result?.clientId, FakeBookingsRepository.newClientId);
    });

    test('confirmar vuelve a leer el directorio (encuentra la ficha nueva) y descarta el borrador', () async {
      fillNewClient();
      await open(newSource);
      final reads = clients.fetchCalls;
      controller(newSource).setPriceText('560');
      await controller(newSource).confirm();
      await pumpEventQueue();
      expect(clients.fetchCalls, reads + 1);
      expect(
        container.read(clientDirectoryProvider).requireValue.map((c) => c.id),
        contains(FakeBookingsRepository.newClientId),
      );
      expect(container.read(newClientFormProvider).isEmpty, isTrue);
      // La pantalla final no cambia: sigue al controller, no al seed.
      expect(state(newSource).result, isNotNull);
      expect(state(newSource).party?.displayName, 'Giulia Rossi');
    });

    test('cambiar los adultos o el idioma en la hoja los escribe en el borrador', () async {
      fillNewClient();
      await open(newSource);
      controller(newSource)
        ..stepHousehold(HouseholdCounter.adults, 1)
        ..toggleMeal(Meal.lunch)
        ..setLocale(ClientLocale.en);
      final draft = container.read(newClientFormProvider);
      expect(draft.household.adults, 3);
      expect(draft.household.meals, [Meal.lunch, Meal.dinner]);
      expect(draft.householdTouched, isTrue);
      expect(draft.locale, ClientLocale.en);
      expect(draft.localeTouched, isTrue);
    });

    test('una ficha existente no escribe en el borrador', () async {
      await open(chiaraSource);
      controller()
        ..stepHousehold(HouseholdCounter.adults, 1)
        ..setLocale(ClientLocale.en);
      expect(container.read(newClientFormProvider).isEmpty, isTrue);
    });
  });

  group('el hogar', () {
    const annaSource = BookingSource.client('c-anna');

    test('a mano, cambiar los adultos recalcula porciones y minutos y pide otro dryRun, hasta tocar los minutos', () async {
      await open(annaSource);
      expect(state(annaSource).cookMinutes, 180);
      expect(state(annaSource).portions, 20);
      final dryRuns = bookings.dryRuns.length;

      controller(annaSource)
        ..stepHousehold(HouseholdCounter.adults, 1)
        ..stepHousehold(HouseholdCounter.adults, 1)
        ..stepHousehold(HouseholdCounter.adults, 1);
      await pumpEventQueue();
      // 5 + 2, 5 días y cena: 35 porciones y 210 minutos.
      expect(state(annaSource).household?.adults, 5);
      expect(state(annaSource).householdEdited, isTrue);
      expect(state(annaSource).portions, 35);
      expect(state(annaSource).cookMinutes, 210);
      // El dryRun se vuelve a pedir cuando cambian los minutos (4 + 2 ya da
      // 210); el hogar no entra en lo que decide el dryRun.
      expect(bookings.dryRuns.length, greaterThan(dryRuns));
      expect(bookings.dryRuns.last.cookMinutes, 210);

      controller(annaSource).stepCookMinutes(1);
      await pumpEventQueue();
      expect(state(annaSource).cookEdited, isTrue);
      controller(annaSource).stepHousehold(HouseholdCounter.adults, 1);
      await pumpEventQueue();
      expect(state(annaSource).portions, 40);
      expect(state(annaSource).cookMinutes, 240, reason: 'los tocó Evelyn');
    });

    test('las comidas: nunca vacías, y cambian la estimación', () async {
      await open(chiaraSource);
      expect(state().cookMinutes, 240);
      controller().toggleMeal(Meal.lunch);
      await pumpEventQueue();
      expect(state().household?.meals, [Meal.dinner]);
      expect(state().cookMinutes, 150);
      controller().toggleMeal(Meal.dinner);
      expect(state().household?.meals, [Meal.dinner], reason: 'la última no se saca');
    });

    test('el idioma no vuelve a pedir el dryRun', () async {
      await open(chiaraSource);
      final dryRuns = bookings.dryRuns.length;
      controller().setLocale(ClientLocale.it);
      await pumpEventQueue();
      expect(state().locale, ClientLocale.it);
      expect(bookings.dryRuns, hasLength(dryRuns));
    });
  });

  group('avisos de la app (no impiden confirmar)', () {
    test('el feriado de una semana', () async {
      await open(chiaraSource);
      controller()
        ..setPriceText('560')
        ..setDate(0, CalendarDate(2027, 1, 6));
      await pumpEventQueue();
      expect(state().holidayFor(0), ItalianHoliday.epiphany);
      expect(state().holidayFor(1), isNull);
      expect(state().canConfirm, isTrue);
    });

    test('hoy, con la llegada ya pasada (14:00 en Roma y llegada a las 10:00)', () async {
      await open(chiaraSource);
      controller()
        ..setPriceText('560')
        ..setDate(0, today);
      await pumpEventQueue();
      expect(state().openedAt, const ClockTime.hm(14, 0));
      expect(state().arrivalPassed(0), isTrue);
      expect(state().arrivalPassed(1), isFalse);
      expect(state().canConfirm, isTrue);
      controller().setStart(const ClockTime.hm(15, 0));
      await pumpEventQueue();
      expect(state().arrivalPassed(0), isFalse);
    });
  });

  group('fallas', () {
    test('la ficha ya no existe: bloquea la hoja y vuelve a leer el directorio', () async {
      bookings.checksFailure = const BookingFailure(BookingFailureKind.notFound);
      final reads = clients.fetchCalls;
      await open(chiaraSource);
      expect(state().failure?.kind, BookingFailureKind.notFound);
      expect(state().blocked, isTrue);
      expect(state().canConfirm, isFalse);
      await pumpEventQueue();
      expect(clients.fetchCalls, reads + 1);
    });

    test('un 400 de la ficha nueva en el dryRun bloquea la hoja', () async {
      bookings.checksFailure = const BookingFailure(
        BookingFailureKind.invalid,
        fields: {'newClient.phone'},
      );
      fillNewClient();
      await open(newSource);
      expect(state(newSource).newClientRejected, isTrue);
      expect(state(newSource).blocked, isTrue);
      controller(newSource).setPriceText('560');
      expect(state(newSource).canConfirm, isFalse);
    });

    test('un 400 de la ficha nueva al confirmar también; uno de otro campo, no', () async {
      fillNewClient();
      await open(newSource);
      controller(newSource).setPriceText('560');
      bookings.confirmFailure = const BookingFailure(
        BookingFailureKind.invalid,
        fields: {'newClient.name'},
      );
      await controller(newSource).confirm();
      expect(state(newSource).newClientRejected, isTrue);
      expect(state(newSource).blocked, isTrue);
      expect(state(newSource).canConfirm, isFalse);

      // Otra hoja: un 400 sin campos de la ficha no bloquea (como el PR 5).
      container.invalidate(confirmBookingProvider(newSource));
      fillNewClient();
      await open(newSource);
      controller(newSource).setPriceText('560');
      bookings.confirmFailure = const BookingFailure(
        BookingFailureKind.invalid,
        fields: {'cookMinutes'},
      );
      await controller(newSource).confirm();
      expect(state(newSource).newClientRejected, isFalse);
      expect(state(newSource).blocked, isFalse);
    });

    test('respuesta perdida: el reintento manda lo mismo con la misma clave y no duplica', () async {
      await open(chiaraSource);
      controller().setPriceText('560');
      bookings.loseNextConfirmResponse = true;
      await controller().confirm();
      expect(state().retryPending, isTrue);
      expect(state().frozen, isTrue);
      controller().stepHousehold(HouseholdCounter.adults, 1);
      expect(state().household, chiaraHousehold, reason: 'nada cambia');

      await controller().confirm();
      final sent = bookings.confirmations;
      expect(sent, hasLength(2));
      expect(sent.last, sent.first);
      expect(sent.last.requestKey, 'key-1');
      expect(state().result?.duplicate, isTrue);
      expect(state().savedDiffers, isFalse);
      expect(bookings.savedByKey, hasLength(1));
    });

    test('sin respuesta al confirmar ni al reintentar: recién ahí se puede cerrar igual («Chiudi comunque»)', () async {
      await open(chiaraSource);
      controller().setPriceText('560');
      bookings.loseNextConfirmResponse = true;
      await controller().confirm();
      expect(state().holdsOpen, isTrue);
      expect(state().canLeaveAnyway, isFalse, reason: 'una respuesta perdida se reintenta');
      controller().leaveAnyway();
      expect(state().holdsOpen, isTrue);

      bookings.confirmFailure = const BookingFailure(BookingFailureKind.unavailable);
      await controller().confirm();
      expect(state().retryPending, isTrue);
      expect(state().canLeaveAnyway, isTrue);
      expect(state().holdsOpen, isTrue, reason: 'hasta que Evelyn lo elige');
      controller().leaveAnyway();
      expect(state().holdsOpen, isFalse);
      expect(state().retryPending, isTrue, reason: 'nada más cambia');
      expect(bookings.confirmations, hasLength(2));
    });

    test('ya guardada con esa clave y otro precio: vale lo guardado y se avisa', () async {
      await open(chiaraSource);
      controller().setPriceText('560');
      bookings.savedByKey['key-1'] = BookingResult(
        dryRun: false,
        duplicate: false,
        requestId: 'manual-request-9',
        clientId: 'c-chiara',
        weeks: [
          for (final date in fourWeeks)
            BookingWeek(
              date: date,
              start: const ClockTime.hm(10, 0),
              cookMinutes: state().cookMinutes,
              status: BookingDayStatus.ok,
              serviceCents: 12500,
            ),
        ],
      );
      await controller().confirm();
      expect(state().result?.duplicate, isTrue);
      expect(state().savedDiffers, isTrue);
    });
  });
}

// Hoja «Confirmar reserva» sin widgets: lo que se prellena desde el pedido,
// lo que dice el dryRun de cada semana, la cadencia de 7 días, el tope de 360
// minutos, el precio (vacío sin precio automático) y la confirmación, con una
// clave por intento que se repite en los reintentos. "Hoy": lunes 19/10/2026.
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
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

const RequestEstimate fourWeeks = fourWeeksEstimate;

void main() {
  final monday = CalendarDate(2026, 11, 23);
  final mondays = weeklyDates(monday, 4);

  late FakeChefRequestsRepository requests;
  late FakeBookingsRepository bookings;
  late FakeSessionsRepository sessions;
  late ProviderContainer container;
  late int keys;

  ChefRequest weekly({
    int weeks = 4,
    RequestEstimate? estimate = fourWeeks,
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
        clockProvider.overrideWithValue(() => testNow),
        newIdProvider.overrideWithValue(() => 'key-${++keys}'),
      ],
    );
    // Como en la app: la bandeja y el pedido ya están cargados al abrir la hoja.
    container
      ..listen(chefInboxProvider, (_, _) {})
      ..listen(chefRequestProvider(request.id), (_, _) {});
    await container.read(chefRequestProvider(request.id).future);
    container.listen(confirmBookingProvider(BookingSource.request(request.id)), (_, _) {});
    await pumpEventQueue();
  }

  ConfirmBookingState state() =>
      container.read(confirmBookingProvider(const BookingSource.request('req-1')));
  ConfirmBookingController controller() =>
      container.read(confirmBookingProvider(const BookingSource.request('req-1')).notifier);

  /// El dryRun que vale para lo que hay ahora en la hoja.
  List<BookingDayStatus?> statuses() => [
    for (var i = 0; i < state().weeks; i++) state().checkFor(i)?.status,
  ];

  setUp(() {
    keys = 0;
    requests = FakeChefRequestsRepository(const []);
    bookings = FakeBookingsRepository(requests: requests);
    sessions = FakeSessionsRepository();
  });

  group('prellenado', () {
    test('las semanas del pedido cada 7 días desde la preferida, los minutos y el precio de la estimación; la hora, del dryRun', () async {
      await open(weekly());

      expect(state().dates, mondays);
      expect(state().maxWeeks, 8);
      expect(state().cookMinutes, 180);
      // El precio de la estimación, sin tocar (la pantalla lo escribe en el
      // campo con el idioma de la interfaz).
      expect(state().priceEdited, isFalse);
      expect(state().suggestedPriceCents, 56000);
      expect(state().serviceTotalCents, 56000);
      // La llegada es la que sugiere el servidor (el comienzo del horario).
      expect(state().start, const ClockTime.hm(10, 0));
      expect(state().startEdited, isFalse);
      expect(state().suggestedStart, const ClockTime.hm(10, 0));

      // Un solo dryRun, sin hora: todas las semanas se evaluaron a las 10:00.
      final dryRun = bookings.dryRuns.single;
      expect(dryRun.requestId, 'req-1');
      expect(dryRun.dates, mondays);
      expect(dryRun.start, isNull);
      expect(dryRun.cookMinutes, 180);
      expect(dryRun.portions, 20);
      expect(dryRun.serviceTotalCents, isNull);
      expect(dryRun.requestKey, isNull);

      expect(state().checksStatus, BookingChecksStatus.ready);
      expect(statuses(), List.filled(4, BookingDayStatus.ok));
      expect(state().canConfirm, isTrue);
    });

    test(
      'los minutos de cocina salen de la estimación, con tope de 360',
      () async {
        await open(weekly(estimate: fourWeeks.copyWith(cookMinutes: 420)));
        expect(state().cookMinutes, 360);

        controller().stepCookMinutes(1);
        expect(state().cookMinutes, 360);
        controller().stepCookMinutes(-1);
        await pumpEventQueue();
        expect(state().cookMinutes, 330);
        expect(bookings.dryRuns.last.cookMinutes, 330);
        expect(bookings.dryRuns.last.start, const ClockTime.hm(10, 0));
      },
    );

    test('sin precio automático el precio queda vacío y no deja confirmar hasta escribirlo', () async {
      await open(
        weekly(
          weeks: 2,
          estimate: const RequestEstimate(
            weeks: 2,
            portions: 30,
            cookMinutes: 240,
            autoPrice: false,
            reason: NoAutoPriceReason.people,
            maxPeople: 5,
          ),
        ),
      );
      expect(state().suggestedPriceCents, isNull);
      expect(state().serviceTotalCents, isNull);
      expect(state().priceIssue, BookingPriceIssue.required);
      expect(state().canConfirm, isFalse);

      controller().setPriceText('380,50');
      expect(state().priceEdited, isTrue);
      expect(state().serviceTotalCents, 38050);
      expect(state().priceIssue, isNull);
      expect(state().canConfirm, isTrue);

      controller().setPriceText('38,0,5');
      expect(state().priceIssue, BookingPriceIssue.invalid);
      controller().setPriceText('100.001');
      expect(state().priceIssue, BookingPriceIssue.tooHigh);
      expect(state().serviceTotalCents, isNull);
      expect(state().canConfirm, isFalse);
      controller().setPriceText('');
      expect(state().priceIssue, BookingPriceIssue.required);
      // 0 vale: sin cargo.
      controller().setPriceText('0');
      expect(state().serviceTotalCents, 0);
      expect(state().canConfirm, isTrue);
    });

    test('una sesión extra: una sola fecha, sin precio automático', () async {
      await open(
        weekly(
          weeks: 1,
          type: RequestType.extra,
          estimate: const RequestEstimate(
            weeks: 1,
            portions: 16,
            cookMinutes: 210,
            autoPrice: false,
            reason: NoAutoPriceReason.extra,
          ),
        ),
      );
      expect(state().maxWeeks, 1);
      expect(state().dates, [monday]);
      controller().setWeeks(2);
      expect(state().dates, [monday]);
      expect(state().serviceTotalCents, isNull);
    });
  });

  group('lo que dice el dryRun de cada semana', () {
    test('avisos (bloqueado, sin horario, fuera de horario, pasada) dejan confirmar; un choque, no', () async {
      bookings.statuses[mondays[1]] = BookingDayStatus.blocked;
      bookings.statuses[mondays[2]] = BookingDayStatus.outside;
      bookings.closedDays.add(mondays[3]);
      await open(weekly());

      // Con un día sin horario, la primera vuelta no alcanza: otra con las 10:00.
      expect(bookings.dryRuns, hasLength(2));
      expect(bookings.dryRuns.last.start, const ClockTime.hm(10, 0));
      expect(statuses(), [
        BookingDayStatus.ok,
        BookingDayStatus.blocked,
        BookingDayStatus.outside,
        BookingDayStatus.closed,
      ]);
      expect(state().hasClash, isFalse);
      expect(state().canConfirm, isTrue);

      bookings.statuses[mondays[0]] = BookingDayStatus.busy;
      controller().setStart(const ClockTime.hm(10, 30));
      await pumpEventQueue();
      expect(state().startEdited, isTrue);
      expect(bookings.dryRuns.last.start, const ClockTime.hm(10, 30));
      expect(statuses().first, BookingDayStatus.busy);
      expect(state().hasClash, isTrue);
      expect(state().canConfirm, isFalse);
    });

    test(
      'una fecha pasada es un aviso: sirve para cargar lo hecho en Fase 0',
      () async {
        final past = CalendarDate(2026, 10, 12);
        bookings.statuses[past] = BookingDayStatus.past;
        await open(
          weekly(
            weeks: 1,
            estimate: fourWeeks.copyWith(weeks: 1, serviceCents: 15000),
          ),
        );
        controller().setDate(0, past);
        await pumpEventQueue();
        expect(statuses(), [BookingDayStatus.past]);
        expect(state().canConfirm, isTrue);
      },
    );

    test('mientras comprueba no deja confirmar', () async {
      await open(weekly());
      bookings.pendingChecks = Completer<void>();
      controller().stepCookMinutes(1);
      await pumpEventQueue();
      expect(state().checksStatus, BookingChecksStatus.loading);
      expect(statuses(), List.filled(4, null));
      expect(state().canConfirm, isFalse);

      bookings.pendingChecks!.complete();
      bookings.pendingChecks = null;
      await pumpEventQueue();
      expect(state().canConfirm, isTrue);
    });

    test('si el dryRun falla avisa y deja confirmar (el servidor vuelve a comprobar); «Riprova» lo pide otra vez', () async {
      bookings.checksFailure = const BookingFailure(
        BookingFailureKind.unavailable,
      );
      await open(weekly());
      expect(state().checksStatus, BookingChecksStatus.failed);
      // Sin sugerida, la llegada por defecto.
      expect(state().start, defaultBookingArrival);
      expect(state().canConfirm, isTrue);

      bookings.checksFailure = null;
      controller().retryChecks();
      await pumpEventQueue();
      expect(state().checksStatus, BookingChecksStatus.ready);
      expect(statuses(), List.filled(4, BookingDayStatus.ok));
    });

    test(
      'un pedido que ya no está nuevo (otro dispositivo) no deja confirmar',
      () async {
        bookings.checksFailure = const BookingFailure(
          BookingFailureKind.requestNotNew,
          requestStatus: 'accepted',
        );
        await open(weekly());
        expect(state().failure?.kind, BookingFailureKind.requestNotNew);
        expect(state().canConfirm, isFalse);
        // Ninguna edición lo destraba.
        controller().stepCookMinutes(1);
        await pumpEventQueue();
        expect(state().failure?.kind, BookingFailureKind.requestNotNew);
        expect(bookings.dryRuns, hasLength(1));
      },
    );

    test('un pedido que ya es una reserva no llama al servidor', () async {
      await open(weekly(status: RequestStatus.accepted));
      expect(bookings.calls, isEmpty);
      expect(state().failure?.kind, BookingFailureKind.requestNotNew);
      expect(state().failure?.requestStatus, 'accepted');
      expect(state().canConfirm, isFalse);
    });

    test(
      'otro dispositivo ya lo confirmó: el dryRun lo dice y la bandeja lo relee',
      () async {
        await open(weekly());
        requests.requests['req-1'] = requests.requests['req-1']!.copyWith(
          status: RequestStatus.accepted,
        );
        controller().stepCookMinutes(1);
        await pumpEventQueue();
        expect(state().failure?.kind, BookingFailureKind.requestNotNew);
        expect(state().failure?.requestStatus, 'accepted');
        expect(state().canConfirm, isFalse);
        // Al cerrar la hoja, el detalle ya no ofrece «Conferma prenotazione».
        final inbox = container.read(chefInboxProvider).requireValue;
        expect(inbox.single.status, RequestStatus.accepted);
        expect(inbox.single.canConfirmBooking, isFalse);
      },
    );

    for (final kind in [
      BookingFailureKind.unauthorized,
      BookingFailureKind.forbidden,
    ]) {
      test('${kind.name} en el dryRun no deja confirmar', () async {
        bookings.checksFailure = BookingFailure(kind);
        await open(weekly());
        expect(state().failure?.kind, kind);
        expect(state().blocked, isTrue);
        expect(state().canConfirm, isFalse);
        // Ninguna edición lo destraba.
        controller().stepCookMinutes(1);
        await pumpEventQueue();
        expect(state().failure?.kind, kind);
        expect(state().canConfirm, isFalse);
      });
    }

    test(
      'vale la respuesta del último dryRun aunque llegue antes que la de uno anterior',
      () async {
        await open(weekly());
        bookings.holdEachCheck = true;
        controller()
          ..stepCookMinutes(1) // 210
          ..stepCookMinutes(1); // 240
        await pumpEventQueue();
        expect(bookings.heldChecks, hasLength(2));

        // Llega primero la de 240: choca.
        bookings.statuses[mondays[0]] = BookingDayStatus.busy;
        bookings.heldChecks[1].complete();
        await pumpEventQueue();
        expect(state().hasClash, isTrue);

        // Después, la de 210 (libre): es de un pedido viejo, no vale.
        bookings.statuses.remove(mondays[0]);
        bookings.heldChecks[0].complete();
        await pumpEventQueue();
        expect(state().cookMinutes, 240);
        expect(statuses().first, BookingDayStatus.busy);
        expect(state().hasClash, isTrue);
        expect(state().canConfirm, isFalse);
      },
    );
  });

  group('lo que impide confirmar (lo dice la barra de abajo)', () {
    test('nada; el precio; una semana que choca; una fecha que no se puede mandar, que va primero', () async {
      await open(weekly());
      expect(state().blocker, isNull);

      controller().setPriceText('');
      expect(state().blocker, (kind: BookingBlockKind.price, week: null));
      controller().setPriceText('560');
      expect(state().blocker, isNull);

      bookings.statuses[mondays[2]] = BookingDayStatus.busy;
      controller().stepCookMinutes(1);
      await pumpEventQueue();
      expect(state().blocker, (kind: BookingBlockKind.clash, week: 2));

      // La segunda, en la misma semana que la primera: está más arriba.
      controller().setDate(1, mondays[0].addDays(2));
      await pumpEventQueue();
      expect(state().blocker, (kind: BookingBlockKind.date, week: 1));
    });
  });

  group('semanas y fechas', () {
    test('sumar semanas agrega cada 7 días; restar saca las últimas; cada cambio vuelve a comprobar', () async {
      await open(weekly());
      controller().setWeeks(6);
      await pumpEventQueue();
      expect(state().dates, weeklyDates(monday, 6));
      expect(bookings.dryRuns.last.dates, weeklyDates(monday, 6));

      controller().setWeeks(2);
      await pumpEventQueue();
      expect(state().dates, weeklyDates(monday, 2));
      expect(bookings.dryRuns.last.dates, weeklyDates(monday, 2));

      controller()
        ..setWeeks(9)
        ..setWeeks(0);
      expect(state().weeks, 2, reason: 'de 1 a 8');
    });

    test('la primera fecha mueve todas; otra, solo la suya', () async {
      await open(weekly());
      controller().setDate(
        2,
        mondays[2].addDays(2),
      ); // la tercera, un miércoles
      await pumpEventQueue();
      expect(state().dates, [
        mondays[0],
        mondays[1],
        mondays[2].addDays(2),
        mondays[3],
      ]);

      controller().setDate(0, monday.addDays(7));
      await pumpEventQueue();
      expect(state().dates, [
        mondays[1],
        mondays[2],
        mondays[3].addDays(2),
        mondays[3].addDays(7),
      ]);
      expect(bookings.dryRuns.last.dates, state().dates);
    });

    test(
      'una fecha en la misma semana que otra no se manda al servidor',
      () async {
        await open(weekly());
        final calls = bookings.dryRuns.length;
        controller().setDate(
          1,
          mondays[0].addDays(3),
        ); // jueves de la primera semana
        await pumpEventQueue();
        expect(state().dateIssues, [
          null,
          BookingDateIssue.sameWeek,
          null,
          null,
        ]);
        expect(bookings.dryRuns, hasLength(calls));
        expect(state().canConfirm, isFalse);
      },
    );

    test('el precio sigue a las semanas mientras no se edita', () async {
      await open(weekly());
      controller().setWeeks(2);
      expect(state().serviceTotalCents, 30000, reason: '2 × 150 €');
      controller().setWeeks(5);
      expect(state().serviceTotalCents, 70000, reason: '5 × 140 €');

      controller().setPriceText('650');
      controller().setWeeks(4);
      expect(
        state().serviceTotalCents,
        65000,
        reason: 'lo que escribió Evelyn no se toca',
      );
      expect(state().priceText, '650');
    });
  });

  group('confirmar', () {
    test('manda la reserva con la hora, el precio en centavos y la clave; el pedido pasa a «Prenotazioni»', () async {
      await open(weekly());
      await controller().confirm();

      final sent = bookings.confirmations.single;
      expect(sent.dryRun, isFalse);
      expect(sent.dates, mondays);
      expect(sent.start, const ClockTime.hm(10, 0));
      expect(sent.cookMinutes, 180);
      expect(sent.serviceTotalCents, 56000);
      expect(sent.portions, 20);
      expect(sent.requestKey, 'key-1');

      expect(state().result?.weeks.map((w) => w.sessionId), [
        'session-1',
        'session-2',
        'session-3',
        'session-4',
      ]);
      expect(state().sending, isFalse);
      expect(state().canConfirm, isFalse, reason: 'ya está confirmada');

      final inbox = container.read(chefInboxProvider).requireValue;
      final booked = inbox.single;
      expect(booked.status, RequestStatus.accepted);
      expect(booked.weeks, 4);
      expect(booked.client.status, ClientStatus.trial);
      expect(inboxTabOf(booked), InboxTab.bookings);
    });

    test('con la agenda ya cargada, al confirmar vuelve a leer las sesiones', () async {
      await open(weekly());
      container.listen(sessionsControllerProvider, (_, _) {});
      await pumpEventQueue();
      final reads = sessions.fetchCalls;

      await controller().confirm();
      await pumpEventQueue();

      expect(sessions.fetchCalls, reads + 1);
    });

    test('sin la agenda abierta no lee sesiones (las lee al abrirla)', () async {
      await open(weekly());
      await controller().confirm();
      await pumpEventQueue();
      expect(sessions.fetchCalls, 0);
    });

    test('mientras envía el botón queda deshabilitado: un segundo toque no manda nada', () async {
      await open(weekly());
      bookings.pendingConfirm = Completer<void>();
      final first = controller().confirm();
      await pumpEventQueue();
      expect(state().sending, isTrue);
      expect(state().canConfirm, isFalse);
      await controller().confirm();
      expect(bookings.confirmations, hasLength(1));
      // Mientras tanto la hoja no cambia: vale lo que se mandó.
      final dryRuns = bookings.dryRuns.length;
      controller()
        ..setWeeks(2)
        ..setDate(1, mondays[1].addDays(1))
        ..setStart(const ClockTime.hm(11, 0))
        ..stepCookMinutes(1)
        ..setPriceText('1');
      await pumpEventQueue();
      expect(state().dates, mondays);
      expect(state().start, const ClockTime.hm(10, 0));
      expect(state().cookMinutes, 180);
      expect(state().priceEdited, isFalse);
      expect(bookings.dryRuns, hasLength(dryRuns));

      bookings.pendingConfirm!.complete();
      await first;
      expect(state().result, isNotNull);
      // Confirmada, tampoco.
      controller().setWeeks(3);
      expect(state().weeks, 4);
    });

    test('un reintento después de una falla usa la misma clave; otra hoja, otra clave', () async {
      await open(weekly());
      bookings.confirmFailure = const BookingFailure(
        BookingFailureKind.unavailable,
      );
      await controller().confirm();
      expect(state().failure?.kind, BookingFailureKind.unavailable);
      expect(state().sending, isFalse);
      expect(state().canConfirm, isTrue);

      bookings.confirmFailure = null;
      await controller().confirm();
      expect(bookings.confirmations.map((c) => c.requestKey), [
        'key-1',
        'key-1',
      ]);
      expect(state().result, isNotNull);

      // Otra vez la hoja con el pedido nuevo (otro intento): clave nueva.
      requests.requests['req-1'] = weekly();
      await container.read(chefInboxProvider.notifier).refresh();
      await container.read(chefRequestProvider('req-1').future);
      container.invalidate(confirmBookingProvider(const BookingSource.request('req-1')));
      expect(state().result, isNull);
      await pumpEventQueue();
      await controller().confirm();
      expect(bookings.confirmations.last.requestKey, 'key-2');
    });

    test(
      'un choque al confirmar dice la fecha, no crea nada y vuelve a comprobar',
      () async {
        await open(weekly());
        bookings
          ..confirmFailure = BookingFailure(
            BookingFailureKind.slotTaken,
            date: mondays[2],
          )
          ..statuses[mondays[2]] = BookingDayStatus.busy;
        final dryRuns = bookings.dryRuns.length;
        await controller().confirm();
        await pumpEventQueue();

        expect(state().failure?.kind, BookingFailureKind.slotTaken);
        expect(state().failure?.date, mondays[2]);
        expect(state().result, isNull);
        expect(bookings.dryRuns, hasLength(dryRuns + 1));
        expect(statuses()[2], BookingDayStatus.busy);
        expect(state().canConfirm, isFalse);
        expect(
          container.read(chefInboxProvider).requireValue.single.status,
          RequestStatus.newRequest,
        );

        // Cambiar esa fecha borra el aviso y vuelve a comprobar.
        bookings.confirmFailure = null;
        controller().setDate(2, mondays[2].addDays(1));
        await pumpEventQueue();
        expect(state().failure, isNull);
        expect(state().canConfirm, isTrue);
      },
    );

    test('sin precio válido no manda nada', () async {
      await open(weekly());
      controller().setPriceText('');
      await controller().confirm();
      expect(bookings.confirmations, isEmpty);
    });

    test('con otras semanas que el pedido, la bandeja guarda las confirmadas', () async {
      await open(weekly());
      controller().setWeeks(6);
      await pumpEventQueue();
      await controller().confirm();

      expect(bookings.confirmations.single.dates, weeklyDates(monday, 6));
      final booked = container.read(chefInboxProvider).requireValue.single;
      expect(booked.weeks, 6);
      expect(booked.status, RequestStatus.accepted);
    });

    test('la ficha pasa a cliente también en sus otros pedidos, no en los de otra persona', () async {
      final other = buildRequest(
        id: 'req-2',
        createdAt: DateTime.utc(2026, 10, 18, 9),
      );
      final stranger = buildRequest(
        id: 'req-3',
        clientId: '33333333-3333-4333-8333-333333333333',
        createdAt: DateTime.utc(2026, 10, 17, 9),
      );
      requests.requests
        ..[other.id] = other
        ..[stranger.id] = stranger;
      await open(weekly());
      await controller().confirm();

      final byId = {
        for (final r in container.read(chefInboxProvider).requireValue) r.id: r,
      };
      expect(byId['req-1']!.client.status, ClientStatus.trial);
      expect(byId['req-2']!.client.status, ClientStatus.trial);
      expect(byId['req-2']!.canMarkClient, isFalse);
      expect(byId['req-2']!.status, RequestStatus.newRequest);
      expect(byId['req-3']!.client.status, ClientStatus.prospect);
    });

    test('otro dispositivo ya lo confirmó: no crea nada y la bandeja lo relee', () async {
      await open(weekly());
      requests.requests['req-1'] = requests.requests['req-1']!.copyWith(
        status: RequestStatus.accepted,
      );
      await controller().confirm();
      await pumpEventQueue();

      expect(state().failure?.kind, BookingFailureKind.requestNotNew);
      expect(state().result, isNull);
      expect(state().canConfirm, isFalse);
      expect(
        container.read(chefInboxProvider).requireValue.single.status,
        RequestStatus.accepted,
      );
    });
  });

  group('confirmación sin respuesta', () {
    test('nada cambia hasta reintentar; el reintento manda lo mismo y el servidor lo reconoce', () async {
      await open(weekly());
      // La base la guarda pero la respuesta se pierde.
      bookings.loseNextConfirmResponse = true;
      await controller().confirm();
      expect(state().failure?.kind, BookingFailureKind.unavailable);
      expect(state().retryPending, isTrue);
      expect(state().frozen, isTrue);
      expect(state().canConfirm, isTrue);

      // Con otros datos el servidor diría que el pedido ya no está nuevo (o
      // ignoraría el precio): nada se puede cambiar.
      final dryRuns = bookings.dryRuns.length;
      controller()
        ..setPriceText('420')
        ..setStart(const ClockTime.hm(11, 0))
        ..setWeeks(3)
        ..stepCookMinutes(1)
        ..setDate(1, mondays[1].addDays(1))
        ..retryChecks();
      await pumpEventQueue();
      expect(state().priceEdited, isFalse);
      expect(state().serviceTotalCents, 56000);
      expect(state().start, const ClockTime.hm(10, 0));
      expect(state().dates, mondays);
      expect(state().cookMinutes, 180);
      expect(bookings.dryRuns, hasLength(dryRuns));
      expect(state().failure?.kind, BookingFailureKind.unavailable);
      // Desde un pedido la hoja se puede cerrar siempre: no hace falta salida.
      expect(state().holdsOpen, isFalse);
      expect(state().canLeaveAnyway, isFalse);

      await controller().confirm();
      final sent = bookings.confirmations;
      expect(sent, hasLength(2));
      expect(sent.last, sent.first, reason: 'la misma clave y los mismos datos');
      expect(state().result?.duplicate, isTrue);
      expect(state().savedDiffers, isFalse);
      expect(state().retryPending, isFalse);
      expect(
        container.read(chefInboxProvider).requireValue.single.status,
        RequestStatus.accepted,
      );
    });

    test('un choque después del reintento sí deja cambiar (no se creó nada)', () async {
      await open(weekly());
      bookings.confirmFailure = const BookingFailure(
        BookingFailureKind.unavailable,
      );
      await controller().confirm();
      expect(state().retryPending, isTrue);

      bookings.confirmFailure = BookingFailure(
        BookingFailureKind.slotTaken,
        date: mondays[1],
      );
      await controller().confirm();
      await pumpEventQueue();
      expect(state().retryPending, isFalse);
      expect(state().frozen, isFalse);
      controller().setDate(1, mondays[1].addDays(1));
      expect(state().dates[1], mondays[1].addDays(1));
    });

    test('ya confirmada desde otro dispositivo con las mismas fechas y hora y otro precio: vale lo guardado y se avisa', () async {
      await open(weekly());
      await bookings.createBooking(
        BookingRequest(
          requestId: 'req-1',
          dates: mondays,
          start: const ClockTime.hm(10, 0),
          cookMinutes: 180,
          serviceTotalCents: 50000,
          requestKey: 'other-device',
        ),
      );
      await controller().confirm();

      expect(state().result?.duplicate, isTrue);
      expect(
        state().result!.weeks.fold<int>(0, (sum, w) => sum + w.serviceCents),
        50000,
      );
      expect(state().savedDiffers, isTrue);
    });
  });
}

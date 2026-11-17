// Hoy sin widgets: qué sesión muestra con el reloj fijo (también a las 23:30
// UTC, que en invierno ya es el día siguiente en Roma), que pasa al día nuevo
// a la medianoche de Roma y a la próxima sesión cuando termina una sin
// reabrir la app, las reservas que terminan, la tira de 7 días con los
// bloqueos y los feriados de la agenda, los enlaces de los botones de abajo,
// deslizar para actualizar y el pedido de abrir la bandeja en «Nuove».
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/application/chef_data_refresh.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/application/inbox_tab_request.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/inbox.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/today/application/today_providers.dart';
import 'package:radici/features/today/domain/today.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  /// Martes 17/11/2026 a las 8:00 en Roma (UTC+1).
  final morning = DateTime.utc(2026, 11, 17, 7);
  final today = CalendarDate(2026, 11, 17);

  late FakeSessionsRepository sessions;
  late FakeAvailabilityRepository availability;
  late FakeChefRequestsRepository requests;

  // El WhatsApp lleva la fecha en el idioma de la clienta.
  setUpAll(initializeDateFormatting);

  setUp(() {
    sessions = FakeSessionsRepository();
    availability = FakeAvailabilityRepository();
    requests = FakeChefRequestsRepository(const []);
  });

  List<Override> overrides(DateTime Function() clock) => [
    authRepositoryProvider.overrideWithValue(FakeAuthRepository(user: chefUser)),
    accountRepositoryProvider.overrideWithValue(
      FakeAccountRepository(chefAccountData),
    ),
    sessionsRepositoryProvider.overrideWithValue(sessions),
    availabilityRepositoryProvider.overrideWithValue(availability),
    chefRequestsRepositoryProvider.overrideWithValue(requests),
    clockProvider.overrideWithValue(clock),
  ];

  /// Con la cuenta de la cocinera ya cargada (el router no deja abrir su área
  /// antes) y algo escuchando Hoy, como la pantalla.
  Future<ProviderContainer> start({DateTime? now}) async {
    final at = now ?? morning;
    final container = ProviderContainer.test(
      retry: noRetry,
      overrides: overrides(() => at),
    );
    container.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
    container
      ..listen(todayFocusProvider, (_, _) {})
      ..listen(todayStripProvider, (_, _) {})
      ..listen(todayEndingBookingsProvider, (_, _) {})
      ..listen(chefInboxProvider, (_, _) {});
    await pumpEventQueue();
    return container;
  }

  CookingSession session(
    int n,
    CalendarDate date, {
    int hour = 10,
    String? requestId = bookingRequestId,
    String? address = 'Via Gombito 12, 24129 Bergamo',
  }) => buildSession(
    n: n,
    date: date,
    start: ClockTime.hm(hour, 0),
    requestId: requestId,
    address: address,
  );

  void save(Iterable<CookingSession> list) {
    for (final s in list) {
      sessions.sessions[s.id] = s;
    }
  }

  group('qué sesión muestra', () {
    test('mientras las sesiones cargan, cargando; después, la de hoy', () async {
      save([session(1, today), session(2, today.addDays(1))]);
      final pending = Completer<void>();
      sessions.pendingFetch = pending;
      final container = await start();
      expect(container.read(todayFocusProvider).isLoading, isTrue);

      pending.complete();
      await pumpEventQueue();
      final focus = container.read(todayFocusProvider).requireValue;
      expect(focus.isToday, isTrue);
      expect(focus.main?.id, sessionId(1));
    });

    test('si las sesiones no se pudieron leer, el error', () async {
      sessions.fetchFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      final container = await start();
      expect(container.read(todayFocusProvider).hasError, isTrue);
    });

    test('a las 23:30 UTC de invierno ya muestra el día siguiente de Roma', () async {
      save([session(1, today, hour: 9), session(2, today.addDays(1))]);
      final container = await start(now: DateTime.utc(2026, 11, 17, 23, 30));
      expect(container.read(romeTodayProvider), CalendarDate(2026, 11, 18));
      final focus = container.read(todayFocusProvider).requireValue;
      expect(focus.isToday, isTrue);
      expect(focus.main?.id, sessionId(2));
    });
  });

  group('sin reabrir la app (reloj falso que avanza con el tiempo del test)', () {
    late DateTime now;
    late ProviderContainer container;

    Future<void> elapse(WidgetTester tester, Duration duration) async {
      now = now.add(duration);
      await tester.pump(duration);
    }

    Future<void> open(WidgetTester tester) async {
      // Sin ProviderContainer.test: los Timer se cancelan antes de que el
      // test termine (testWidgets falla si queda alguno pendiente).
      container = ProviderContainer(
        retry: noRetry,
        overrides: overrides(() => now),
      );
      container.listen(sessionControllerProvider, (_, _) {});
      await tester.pump();
      container.listen(todayFocusProvider, (_, _) {});
      await tester.pump();
      await tester.pump();
    }

    TodayFocus focus() => container.read(todayFocusProvider).requireValue;

    testWidgets('a la medianoche de Roma la sesión de mañana pasa a ser la de hoy', (
      tester,
    ) async {
      save([session(1, CalendarDate(2026, 11, 18))]);
      // 23:59:30 del martes 17/11 en Roma.
      now = DateTime.utc(2026, 11, 17, 22, 59, 30);
      await open(tester);
      expect(focus().isToday, isFalse);
      expect(focus().main?.id, sessionId(1));

      await elapse(tester, const Duration(seconds: 30));
      expect(container.read(romeTodayProvider), CalendarDate(2026, 11, 18));
      expect(focus().isToday, isTrue);
      expect(focus().main?.id, sessionId(1));
      container.dispose();
    });

    testWidgets('cuando termina la sesión de hoy, la próxima del día queda primera', (
      tester,
    ) async {
      save([session(1, today), session(2, today, hour: 16)]);
      // 12:59:30 en Roma: la de las 10:00 cocina hasta las 13:00.
      now = DateTime.utc(2026, 11, 17, 11, 59, 30);
      await open(tester);
      expect(focus().main?.id, sessionId(1));

      await elapse(tester, const Duration(seconds: 30));
      expect(focus().main?.id, sessionId(2));
      expect(focus().sessions.last.id, sessionId(1));
      container.dispose();
    });

    testWidgets('después de una suspensión lo nota en menos de un minuto', (
      tester,
    ) async {
      save([session(1, today), session(2, today, hour: 16)]);
      now = DateTime.utc(2026, 11, 17, 8);
      await open(tester);
      expect(focus().main?.id, sessionId(1));

      // Durante la suspensión el reloj del sistema avanza pero los Timer no.
      now = DateTime.utc(2026, 11, 17, 14);
      await tester.pump(todayNowRecheck);
      expect(focus().main?.id, sessionId(2));
      container.dispose();
    });
  });

  test('reservas que terminan: la última semana de cada una en los próximos 7 días', () async {
    save([
      ...buildBooking(first: CalendarDate(2026, 10, 28)),
      buildSession(
        n: 9,
        date: CalendarDate(2026, 11, 25),
        requestId: 'otra',
      ),
    ]);
    final container = await start();
    final ending = container.read(todayEndingBookingsProvider);
    // La reserva de prueba: 28/10, 4/11, 11/11 y 18/11.
    expect([for (final s in ending) s.id], [sessionId(4)]);
  });

  group('la tira de 7 días', () {
    test('con las sesiones, los bloqueos y los feriados de la agenda', () async {
      final monday = DateTime.utc(2026, 12, 7, 7);
      availability.blocked[CalendarDate(2026, 12, 9)] = BlockedDay(
        id: 'block-1',
        date: CalendarDate(2026, 12, 9),
      );
      save([session(1, CalendarDate(2026, 12, 10))]);
      final container = await start(now: monday);
      final strip = container.read(todayStripProvider);
      expect(strip.first.date, CalendarDate(2026, 12, 7));
      expect(strip.length, 7);
      expect(strip[1].holiday, ItalianHoliday.immaculate);
      expect(strip[1].status, DayStatus.open);
      expect(strip[2].isBlocked, isTrue);
      expect(strip[3].sessionCount, 1);
      expect(strip[5].status, DayStatus.closed);
    });

    test('mientras la disponibilidad no está, sin estado (las sesiones igual)', () async {
      availability.failFetch = true;
      save([session(1, today)]);
      final container = await start();
      final strip = container.read(todayStripProvider);
      expect(strip.every((day) => day.status == null), isTrue);
      expect(strip.first.sessionCount, 1);
    });
  });

  group('los botones de abajo, para la primera sesión', () {
    test('«Cómo llegar» en Apple Maps o Google Maps y WhatsApp', () async {
      save([session(1, today)]);
      final container = await start();
      final links = container.read(todayLinksProvider)!;
      expect(links.directions.toString(), startsWith('https://www.google.com/maps/dir/'));
      expect(links.whatsApp.toString(), startsWith('https://wa.me/393331234567?text='));

      final apple = ProviderContainer.test(
        retry: noRetry,
        overrides: [
          ...overrides(() => morning),
          appleMapsProvider.overrideWithValue(true),
        ],
      );
      apple.listen(sessionControllerProvider, (_, _) {});
      await pumpEventQueue();
      apple.listen(todayFocusProvider, (_, _) {});
      await pumpEventQueue();
      expect(
        apple.read(todayLinksProvider)!.directions.toString(),
        startsWith('https://maps.apple.com/?daddr='),
      );
    });

    test('sin dirección no hay «Cómo llegar»; sin sesiones, nada', () async {
      save([session(1, today, address: null)]);
      final container = await start();
      expect(container.read(todayLinksProvider)!.directions, isNull);
      expect(container.read(todayLinksProvider)!.whatsApp, isNotNull);

      sessions.sessions.clear();
      await container.read(sessionsControllerProvider.notifier).refresh();
      expect(container.read(todayLinksProvider), isNull);
    });
  });

  group('deslizar para actualizar', () {
    test('vuelve a leer la bandeja, la disponibilidad y las sesiones', () async {
      final container = await start();
      final before = (
        sessions: sessions.fetchCalls,
        availability: availability.fetchCalls,
      );
      save([session(1, today)]);
      final ok = await container.read(refreshChefDataProvider)();
      expect(ok, isTrue);
      expect(sessions.fetchCalls, before.sessions + 1);
      expect(availability.fetchCalls, before.availability + 1);
      expect(container.read(todayFocusProvider).requireValue.main?.id, sessionId(1));
    });

    test('si una falla, devuelve false y queda lo que había', () async {
      save([session(1, today)]);
      final container = await start();
      sessions.fetchFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      final ok = await container.read(refreshChefDataProvider)();
      expect(ok, isFalse);
      expect(container.read(todayFocusProvider).requireValue.main?.id, sessionId(1));
    });
  });

  test('el pedido de abrir la bandeja en una pestaña es nuevo cada vez', () {
    final container = ProviderContainer.test();
    expect(container.read(inboxTabRequestProvider), isNull);
    container.read(inboxTabRequestProvider.notifier).show(InboxTab.fresh);
    final first = container.read(inboxTabRequestProvider)!;
    expect(first.tab, InboxTab.fresh);
    container.read(inboxTabRequestProvider.notifier).show(InboxTab.fresh);
    final second = container.read(inboxTabRequestProvider)!;
    expect(second.tab, InboxTab.fresh);
    expect(second.serial, greaterThan(first.serial));
    expect(second, isNot(first));
  });
}

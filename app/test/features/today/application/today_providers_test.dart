// Hoy sin widgets: qué sesión muestra con el reloj fijo (también a las 23:30
// UTC, que en invierno ya es el día siguiente en Roma), que pasa al día nuevo
// a la medianoche de Roma y a la próxima sesión cuando termina una sin
// reabrir la app (minuto a minuto, no solo una vez), las reservas que
// terminan (con el día de Roma, de 7 días antes a 7 días después: la agenda
// lee desde 7 días antes de hoy; una renovada desde este dispositivo
// desaparece aunque la agenda no se relea), la tira de 7 días con los
// bloqueos y los feriados de la agenda (sin estado mientras la disponibilidad
// se vuelve a leer), los enlaces de los botones de abajo (el WhatsApp con la
// regla de la ficha: de parte de la cocinera con la cuenta de un
// colaborador; la hora de llegada solo en una sesión que no está cancelada,
// cocinada ni cobrada, de hoy en adelante; nunca la dirección, las alergias,
// las notas, la zona ni el apellido), deslizar para actualizar y el pedido de
// abrir la bandeja en «Nuove».
import 'dart:async';
import 'dart:ui' show Locale;

import 'package:fake_async/fake_async.dart';
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
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/application/chef_data_refresh.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/application/inbox_tab_request.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';
import 'package:radici/features/sessions/application/renewed_bookings.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/today/application/today_providers.dart';
import 'package:radici/features/today/domain/today.dart';
import 'package:radici/l10n/app_localizations.dart';

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

  /// [account]: la de la cocinera; con un colaborador, la de él.
  List<Override> overrides(
    DateTime Function() clock, {
    Account account = chefAccountData,
  }) => [
    authRepositoryProvider.overrideWithValue(FakeAuthRepository(user: chefUser)),
    accountRepositoryProvider.overrideWithValue(FakeAccountRepository(account)),
    sessionsRepositoryProvider.overrideWithValue(sessions),
    availabilityRepositoryProvider.overrideWithValue(availability),
    chefRequestsRepositoryProvider.overrideWithValue(requests),
    clockProvider.overrideWithValue(clock),
  ];

  /// Con la cuenta de la cocinera ([account]; la de un colaborador, si se
  /// pasa) ya cargada (el router no deja abrir su área antes) y algo
  /// escuchando Hoy, como la pantalla. [retry]: los reintentos automáticos de
  /// Riverpod (por defecto, ninguno).
  Future<ProviderContainer> start({
    DateTime? now,
    RetryDelay retry = noRetry,
    Account account = chefAccountData,
  }) async {
    final at = now ?? morning;
    final container = ProviderContainer.test(
      retry: retry,
      overrides: overrides(() => at, account: account),
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
    SessionStatus status = SessionStatus.confirmed,
  }) => buildSession(
    n: n,
    date: date,
    start: ClockTime.hm(hour, 0),
    requestId: requestId,
    address: address,
    status: status,
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

    /// [start] con el tiempo simulado de [async]: avanza solo lo justo para
    /// que termine (sus vueltas por la cola de eventos, a 0 ms), así el
    /// reintento a los 20 ms no sale antes de mirar por más lenta que esté la
    /// máquina (con el reloj real, a veces salía).
    ProviderContainer startFake(FakeAsync async, {required RetryDelay retry}) {
      ProviderContainer? container;
      unawaited(start(retry: retry).then((started) => container = started));
      async.elapse(Duration.zero);
      return container!;
    }

    test('mientras Riverpod reintenta una primera lectura que falló, cargando (no el error); si deja de reintentar, el error', () {
      fakeAsync((async) {
        sessions.fetchFailure = const SessionFailure(
          SessionFailureKind.unavailable,
        );
        final container = startFake(
          async,
          retry: retryOnce(const Duration(milliseconds: 20)),
        );
        expect(
          container.read(sessionsControllerProvider),
          isA<AsyncLoading<List<CookingSession>>>().having(
            (s) => s.hasError,
            'con el error',
            isTrue,
          ),
          reason: 'esperando el reintento',
        );
        final retrying = container.read(todayFocusProvider);
        expect(retrying.isLoading, isTrue);
        expect(retrying.hasError, isFalse);
        expect(sessions.fetchCalls, 1);

        async.elapse(const Duration(milliseconds: 60));
        expect(sessions.fetchCalls, 2);
        expect(container.read(todayFocusProvider).hasError, isTrue);
      });
    });

    test('si el reintento automático sale bien, la sesión', () {
      fakeAsync((async) {
        save([session(1, today)]);
        sessions.fetchFailure = const SessionFailure(
          SessionFailureKind.unavailable,
        );
        final container = startFake(
          async,
          retry: retryOnce(const Duration(milliseconds: 20)),
        );
        expect(container.read(todayFocusProvider).isLoading, isTrue);

        sessions.fetchFailure = null;
        async.elapse(const Duration(milliseconds: 60));
        expect(
          container.read(todayFocusProvider).requireValue.main?.id,
          sessionId(1),
        );
      });
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

    testWidgets('el reloj sigue avanzando después del primer cambio de minuto', (
      tester,
    ) async {
      save([session(1, today), session(2, today, hour: 16)]);
      // 12:58:30 en Roma: el primer cambio de minuto (12:59) no termina la de
      // las 10:00, que cocina hasta las 13:00; el segundo (13:00), sí.
      now = DateTime.utc(2026, 11, 17, 11, 58, 30);
      await open(tester);
      expect(focus().main?.id, sessionId(1));

      await elapse(tester, const Duration(seconds: 30));
      expect(focus().main?.id, sessionId(1), reason: '12:59');

      await elapse(tester, const Duration(minutes: 1));
      expect(focus().main?.id, sessionId(2), reason: '13:00');
      container.dispose();
    });

    testWidgets('después de una suspensión lo nota como mucho en un minuto', (
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

    testWidgets('al cambiar de mes, mientras la disponibilidad se vuelve a leer, la tira queda sin estado', (
      tester,
    ) async {
      // 23:59:30 del lunes 30/11 en Roma: a la medianoche cambia el mes y la
      // disponibilidad se vuelve a leer.
      now = DateTime.utc(2026, 11, 30, 22, 59, 30);
      await open(tester);
      container.listen(todayStripProvider, (_, _) {});
      await tester.pump();
      await tester.pump();
      expect(container.read(todayStripProvider).first.status, DayStatus.open);

      availability.pendingFetch = Completer<void>();
      await elapse(tester, const Duration(seconds: 30));
      expect(container.read(romeTodayProvider), CalendarDate(2026, 12, 1));
      expect(
        [for (final day in container.read(todayStripProvider)) day.status].nonNulls,
        isEmpty,
        reason: 'el estado viejo no vale para el mes nuevo',
      );

      availability.pendingFetch!.complete();
      await tester.pump();
      await tester.pump();
      final strip = container.read(todayStripProvider);
      expect(strip.first.date, CalendarDate(2026, 12, 1));
      expect(strip.first.status, DayStatus.open);
      container.dispose();
    });
  });

  test('reservas que terminan: la última semana de cada una, de 7 días antes a 7 después', () async {
    save([
      ...buildBooking(first: CalendarDate(2026, 10, 28)),
      // Otra ficha, con su última sesión dentro de 8 días.
      buildSession(
        n: 9,
        date: CalendarDate(2026, 11, 25),
        requestId: 'otra',
        clientId: 'otra-ficha',
      ),
    ]);
    final container = await start();
    final ending = container.read(todayEndingBookingsProvider);
    // La reserva de prueba: 28/10, 4/11, 11/11 y 18/11.
    expect([for (final s in ending) s.id], [sessionId(4)]);
  });

  test('reservas que terminan con el día de Roma: a las 23:30 UTC del 17/11 la ventana ya va del 11 al 25', () async {
    save([
      // Su última sesión es el 10/11: en Roma ya es hoy − 8.
      buildSession(
        n: 1,
        date: CalendarDate(2026, 11, 10),
        requestId: 'hace-ocho',
        clientId: 'ficha-1',
      ),
      // El 25/11 es hoy + 7 en Roma.
      buildSession(
        n: 2,
        date: CalendarDate(2026, 11, 25),
        requestId: 'en-siete',
        clientId: 'ficha-2',
      ),
    ]);
    final container = await start(now: DateTime.utc(2026, 11, 17, 23, 30));
    expect(
      [for (final s in container.read(todayEndingBookingsProvider)) s.requestId],
      ['en-siete'],
    );
  });

  group('reservas que terminan, al renovar', () {
    // La reserva de prueba: 28/10, 4/11, 11/11 y 18/11 (termina mañana).
    test('cuando la agenda trae las sesiones de la renovación (la misma ficha, después), el pendiente desaparece', () async {
      save(buildBooking(first: CalendarDate(2026, 10, 28)));
      final container = await start();
      expect(
        [for (final s in container.read(todayEndingBookingsProvider)) s.id],
        [sessionId(4)],
      );
      save(
        buildBooking(
          first: CalendarDate(2026, 11, 25),
          firstN: 10,
          requestId: 'renovacion',
        ),
      );
      await container.read(sessionsControllerProvider.notifier).refresh();
      expect(container.read(todayEndingBookingsProvider), isEmpty);
    });

    test('con la reserva marcada como renovada desde este dispositivo, desaparece aunque las sesiones no se puedan volver a leer', () async {
      save(buildBooking(first: CalendarDate(2026, 10, 28)));
      final container = await start();
      expect(container.read(todayEndingBookingsProvider), hasLength(1));
      sessions.fetchFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      await container.read(sessionsControllerProvider.notifier).refreshQuietly();
      container
          .read(renewedBookingsProvider.notifier)
          .mark(bookingRequestId, CalendarDate(2026, 11, 25));
      expect(container.read(todayEndingBookingsProvider), isEmpty);
    });

    test('una reserva marcada no saca las de otros pedidos', () async {
      save([
        ...buildBooking(first: CalendarDate(2026, 10, 28)),
        buildSession(
          n: 9,
          date: CalendarDate(2026, 11, 20),
          requestId: 'otra',
          clientId: 'otra-ficha',
        ),
      ]);
      final container = await start();
      container
          .read(renewedBookingsProvider.notifier)
          .mark(bookingRequestId, CalendarDate(2026, 11, 25));
      expect(
        [for (final s in container.read(todayEndingBookingsProvider)) s.requestId],
        ['otra'],
      );
    });
  });

  test('la agenda lee desde 7 días antes de hoy cuando el mes acaba de empezar: Hoy ve la reserva que terminó', () async {
    // Jueves 3/12/2026: la agenda empezaría el lunes 30/11 y la última sesión
    // de la reserva fue el jueves 26/11 (hoy − 7).
    save(buildBooking(first: CalendarDate(2026, 11, 5)));
    final container = await start(now: DateTime.utc(2026, 12, 3, 7));
    expect(sessions.fetchedFrom.last, CalendarDate(2026, 11, 26));
    expect(
      [for (final s in container.read(todayEndingBookingsProvider)) s.date],
      [CalendarDate(2026, 11, 26)],
    );
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

  group('el WhatsApp de abajo, con la regla de la ficha (sessionLinksFor)', () {
    // Sale del teléfono de quien usa la app: con la cuenta de un colaborador
    // escribe de parte de la cocinera, sin decir que es ella ni que es quien
    // llega. La hora de llegada va solo en una sesión que no está cancelada,
    // cocinada ni cobrada, de hoy en adelante: hoy es el día de Roma
    // (romeTodayProvider), el mismo con que Hoy elige la sesión.
    final collaboratorData = chefAccountData.copyWith(
      chef: chefAccount.copyWith(collaborator: true),
    );

    /// 14:00 del martes 17/11 en Roma: la sesión de las 10:00 terminó a las
    /// 13:00.
    final afternoon = DateTime.utc(2026, 11, 17, 13);

    /// El texto del WhatsApp de los botones de abajo en [now] (por defecto, el
    /// martes 17/11 a las 8:00 en Roma), con la cuenta de la cocinera o, con
    /// [collaborator], la de un colaborador suyo.
    Future<String> whatsAppText({
      bool collaborator = false,
      DateTime? now,
    }) async {
      final container = await start(
        now: now,
        account: collaborator ? collaboratorData : chefAccountData,
      );
      return container
          .read(todayLinksProvider)!
          .whatsApp!
          .queryParameters['text']!;
    }

    test('con la cuenta de la cocinera lo firma ella: la sesión de hoy, con su fecha y la hora de llegada', () async {
      save([session(1, today)]);
      expect(
        await whatsAppText(),
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'martedì 17 novembre, con arrivo alle 10:00.',
      );
    });

    test('con la cuenta de un colaborador, de parte de la cocinera: ni «sono Evelyn» ni que llega él', () async {
      save([session(1, today)]);
      expect(
        await whatsAppText(collaborator: true),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione '
        'di martedì 17 novembre, con arrivo di Evelyn alle 10:00.',
      );
    });

    test('la próxima sesión, de otro día: con su fecha y la hora de llegada', () async {
      // Hoy no hay ninguna: los botones son de la del jueves 19.
      save([session(1, today.addDays(2)), session(2, today.addDays(9))]);
      expect(
        await whatsAppText(),
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'giovedì 19 novembre, con arrivo alle 10:00.',
      );
      expect(
        await whatsAppText(collaborator: true),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione '
        'di giovedì 19 novembre, con arrivo di Evelyn alle 10:00.',
      );
    });

    test('hoy sale del reloj de la app, no del reloj del sistema', () async {
      // Lunes 19/10/2026 a las 14:00 en Roma: la próxima es la del miércoles
      // 21/10, que para el reloj del sistema ya pasó. Que hoy sea el día de
      // Roma y no el de UTC no se ve en Hoy: todayFocus solo deja sesiones de
      // hoy en adelante en Roma, y en UTC la fecha nunca es posterior a la de
      // Roma, así que con los dos la de los botones es de hoy en adelante. Lo
      // distinguen los tests de la ficha (session_links_test y
      // cooking_session_screen_test).
      save([session(1, CalendarDate(2026, 10, 21))]);
      expect(
        await whatsAppText(now: DateTime.utc(2026, 10, 19, 12)),
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'mercoledì 21 ottobre, con arrivo alle 10:00.',
      );
    });

    test('una de hoy ya cocinada o cobrada (terminadas las de hoy, es la de los botones): con su fecha, sin la hora de llegada', () async {
      for (final status in [SessionStatus.cooked, SessionStatus.paid]) {
        save([session(1, today, status: status)]);
        expect(
          await whatsAppText(now: afternoon),
          'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
          'martedì 17 novembre.',
          reason: status.name,
        );
        expect(
          await whatsAppText(collaborator: true, now: afternoon),
          'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione '
          'di martedì 17 novembre.',
          reason: status.name,
        );
      }
    });

    test('nunca la dirección, las alergias, las notas, la zona ni el apellido: cocinera o colaborador, con la hora de llegada o sin ella, en los tres idiomas', () async {
      // De hoy con la llegada, de hoy ya cocinada (sin la llegada) y la
      // próxima, de otro día.
      final cases = [
        (date: today, status: SessionStatus.confirmed, now: morning),
        (date: today, status: SessionStatus.cooked, now: afternoon),
        (date: today.addDays(2), status: SessionStatus.confirmed, now: morning),
      ];
      for (final locale in ClientLocale.values) {
        final l10n = lookupAppLocalizations(Locale(locale.name));
        // Una sesión con todo: la dirección de la ficha, sus alérgenos, los
        // del pedido, la dieta, la nota de alergias, las notas de la cocina y
        // del pedido (el portero), la zona y el apellido.
        final secrets = [
          'Gombito',
          '24129',
          'Celiachia',
          'noci',
          l10n.allergenGluten,
          l10n.allergenMilk,
          l10n.dietVegetarian,
          'Forno a gas',
          'Citofono',
          'Città Alta',
          'Rossi',
        ];
        for (final c in cases) {
          sessions.sessions.clear();
          save([
            buildSession(
              date: c.date,
              status: c.status,
              locale: locale,
              clientAllergens: const [Allergen.gluten],
              restrictions: const RequestRestrictions(
                allergens: [Allergen.milk],
                diets: [Diet.vegetarian],
                note: 'Celiachia, noci',
              ),
              noAllergies: false,
            ),
          ]);
          for (final collaborator in [false, true]) {
            final text = await whatsAppText(
              collaborator: collaborator,
              now: c.now,
            );
            final reason =
                '${locale.name}, ${c.status.name} del ${c.date.toIso()}, '
                'colaborador: $collaborator';
            // El de esa sesión, con el nombre de pila de la clienta.
            expect(text, contains('Giulia'), reason: reason);
            for (final secret in secrets) {
              expect(text, isNot(contains(secret)), reason: reason);
            }
          }
        }
      }
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

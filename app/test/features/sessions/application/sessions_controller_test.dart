// Sesiones sin widgets: lo que lee la agenda (desde qué día, las vivas por
// día), la ficha de una sesión con las semanas de su reserva, mover y
// cancelar con la Edge Function (también las que ya estaban canceladas en
// otro dispositivo) y la dirección de la ficha, que se aplican en la agenda y
// en las fichas abiertas sin volver a leer, y qué sesiones esperan al
// servidor. "Hoy": lunes 19/10/2026 (testNow).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  late FakeSessionsRepository repository;
  late FakeAuthRepository auth;
  late ProviderContainer container;

  Future<void> start({bool agenda = true}) async {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        sessionsRepositoryProvider.overrideWithValue(repository),
        clockProvider.overrideWithValue(() => testNow),
      ],
    );
    // La cuenta de la cocinera ya cargada, como en la app (el router no deja
    // abrir el área antes).
    container.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
    // Como en la agenda: algo la escucha todo el tiempo.
    if (agenda) container.listen(sessionsControllerProvider, (_, _) {});
    await pumpEventQueue();
  }

  List<CookingSession> window() =>
      container.read(sessionsControllerProvider).requireValue;

  setUp(() {
    auth = FakeAuthRepository(user: chefUser);
    repository = FakeSessionsRepository(buildBooking());
  });

  group('agenda', () {
    test('lee las de la cocinera desde el lunes de la primera semana del mes de hoy', () async {
      await start();
      expect(repository.fetchedFrom, [CalendarDate(2026, 9, 28)]);
      expect(window().map((s) => s.id), [
        for (var n = 1; n <= 4; n++) sessionId(n),
      ]);
    });

    test('por día solo las vivas, por llegada', () async {
      final day = CalendarDate(2026, 11, 25);
      repository.sessions[sessionId(9)] = buildSession(
        n: 9,
        date: day,
        requestId: 'otra',
        start: const ClockTime.hm(8, 30),
      );
      repository.sessions[sessionId(8)] = buildSession(
        n: 8,
        date: day,
        requestId: 'otra-mas',
        status: SessionStatus.cancelled,
      );
      await start();
      final byDate = container.read(agendaSessionsByDateProvider);
      expect(byDate[day]!.map((s) => s.id), [sessionId(9), sessionId(1)]);
    });

    test('sin sesión de cocinera queda vacía y no llama al servidor', () async {
      auth = FakeAuthRepository();
      await start();
      expect(window(), isEmpty);
      expect(repository.fetchCalls, 0);
    });

    test(
      'al elegir un mes anterior vuelve a leer desde ahí; uno posterior no',
      () async {
        await start();
        final agenda = container.read(agendaControllerProvider.notifier);

        agenda.select(CalendarDate(2027, 1, 13));
        await pumpEventQueue();
        expect(repository.fetchedFrom, [CalendarDate(2026, 9, 28)]);

        agenda.select(CalendarDate(2026, 8, 10));
        await pumpEventQueue();
        expect(repository.fetchedFrom, [
          CalendarDate(2026, 9, 28),
          CalendarDate(2026, 7, 27),
        ]);
      },
    );

    test(
      'deslizar para actualizar: si falla, queda lo que había y avisa',
      () async {
        await start();
        repository.fetchFailure = const SessionFailure(
          SessionFailureKind.unavailable,
        );
        await expectLater(
          container.read(sessionsControllerProvider.notifier).refresh(),
          throwsA(isA<SessionFailure>()),
        );
        expect(window(), hasLength(4));

        // refreshQuietly no avisa.
        await container
            .read(sessionsControllerProvider.notifier)
            .refreshQuietly();
        expect(window(), hasLength(4));
      },
    );

    test('una lectura que se cruza con un cambio se descarta y se lee otra vez', () async {
      await start();
      final gate = Completer<void>();
      repository.pendingFetch = gate;
      final refresh = container
          .read(sessionsControllerProvider.notifier)
          .refresh();
      await pumpEventQueue();
      // Mientras tanto se cancela una semana: la lectura en curso es de antes.
      repository.pendingFetch = null;
      await container.read(sessionCommandsProvider).cancel([
        repository.sessions[sessionId(2)]!,
      ]);
      gate.complete();
      await refresh;
      expect(repository.fetchCalls, 3);
      expect(
        window().firstWhere((s) => s.id == sessionId(2)).status,
        SessionStatus.cancelled,
      );
    });
  });

  group('mover y cancelar se aplican sin volver a leer', () {
    test('mover cambia la fecha y la hora en la agenda', () async {
      await start();
      final reads = repository.fetchCalls;
      final session = window().first;

      final moved = await container
          .read(sessionCommandsProvider)
          .move(
            session,
            date: CalendarDate(2026, 11, 27),
            start: const ClockTime.hm(11, 0),
          );

      expect(moved.date, CalendarDate(2026, 11, 27));
      expect(repository.moves.single.start, const ClockTime.hm(11, 0));
      final updated = window().firstWhere((s) => s.id == session.id);
      expect(updated.date, CalendarDate(2026, 11, 27));
      expect(updated.start, const ClockTime.hm(11, 0));
      expect(
        container
            .read(agendaSessionsByDateProvider)[CalendarDate(2026, 11, 27)]
            ?.single
            .id,
        session.id,
      );
      expect(repository.fetchCalls, reads);
    });

    test('una movida antes de lo que lee la agenda sale de la lista', () async {
      await start();
      await container
          .read(sessionCommandsProvider)
          .move(
            window().first,
            date: CalendarDate(2026, 9, 2),
            start: const ClockTime.hm(10, 0),
          );
      expect(window().map((s) => s.id), isNot(contains(sessionId(1))));
    });

    test('cancelar la marca cancelada (con el motivo) y sale de los días de la agenda', () async {
      await start();
      final session = window()[1];
      final result = await container.read(sessionCommandsProvider).cancel([
        session,
      ], reason: CancelReason.clientCancelled);

      expect(result.cancelled, [session.id]);
      expect(
        repository.cancelCalls.single.reason,
        CancelReason.clientCancelled,
      );
      final cancelled = window().firstWhere((s) => s.id == session.id);
      expect(cancelled.status, SessionStatus.cancelled);
      expect(cancelled.cancelReason, 'client_cancelled');
      expect(cancelled.cancelledAt, testNow);
      expect(
        container.read(agendaSessionsByDateProvider)[session.date],
        isNull,
      );
    });

    test('si falla no cambia nada y relanza SessionFailure', () async {
      await start();
      repository.cancelFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      await expectLater(
        container.read(sessionCommandsProvider).cancel([window().first]),
        throwsA(
          isA<SessionFailure>().having(
            (f) => f.kind,
            'kind',
            SessionFailureKind.unavailable,
          ),
        ),
      );
      expect(window().first.status, SessionStatus.confirmed);
      expect(container.read(sessionChangesProvider), isNull);
    });

    test(
      'las que ya estaban canceladas en otro dispositivo (alreadyCancelled) también se marcan, en la agenda y en la ficha',
      () async {
        await start();
        container.listen(sessionDetailProvider(sessionId(1)), (_, _) {});
        await container.read(sessionDetailProvider(sessionId(1)).future);
        // Otro dispositivo cancela la 3; acá todavía se ve viva.
        repository.sessions[sessionId(3)] = repository.sessions[sessionId(3)]!
            .copyWith(status: SessionStatus.cancelled);
        expect(window()[2].isLive, isTrue);

        final result = await container.read(sessionCommandsProvider).cancel([
          window()[1],
          window()[2],
        ]);

        expect(result.cancelled, [sessionId(2)]);
        expect(result.alreadyCancelled, [sessionId(3)]);
        for (final id in [sessionId(2), sessionId(3)]) {
          expect(
            window().firstWhere((s) => s.id == id).status,
            SessionStatus.cancelled,
            reason: id,
          );
        }
        final open = container.read(sessionDetailProvider(sessionId(1))).value!;
        expect(
          open.booking.firstWhere((s) => s.id == sessionId(3)).status,
          SessionStatus.cancelled,
        );
        expect(open.position, (week: 1, weeks: 2));
      },
    );
  });

  group('esperando al servidor (los botones de la ficha, deshabilitados)', () {
    test('mover marca la sesión mientras espera y la desmarca al terminar', () async {
      await start();
      repository.pendingMove = Completer<void>();
      final move = container
          .read(sessionCommandsProvider)
          .move(
            window().first,
            date: CalendarDate(2026, 11, 27),
            start: const ClockTime.hm(10, 0),
          );
      await pumpEventQueue();
      expect(container.read(sessionsBusyProvider), {sessionId(1)});

      repository.pendingMove!.complete();
      await move;
      expect(container.read(sessionsBusyProvider), isEmpty);
    });

    test('cancelar marca todas las pedidas, y las desmarca también si falla', () async {
      await start();
      repository
        ..pendingCancel = Completer<void>()
        ..cancelFailure = const SessionFailure(SessionFailureKind.unavailable);
      final cancel = container.read(sessionCommandsProvider).cancel([
        window()[1],
        window()[2],
      ]);
      await pumpEventQueue();
      expect(container.read(sessionsBusyProvider), {
        sessionId(2),
        sessionId(3),
      });

      repository.pendingCancel!.complete();
      await expectLater(cancel, throwsA(isA<SessionFailure>()));
      expect(container.read(sessionsBusyProvider), isEmpty);
    });
  });

  group('la dirección de la ficha', () {
    test(
      'se guarda y se ve en todas las sesiones de esa ficha, en la agenda y en la ficha abierta, sin volver a leer',
      () async {
        // Otra clienta, sin dirección: no cambia.
        repository.sessions[sessionId(9)] = buildSession(
          n: 9,
          requestId: 'otra',
          date: CalendarDate(2026, 11, 26),
          address: null,
        ).copyWith(clientId: 'otra-ficha');
        await start();
        container.listen(sessionDetailProvider(sessionId(1)), (_, _) {});
        final loaded = await container.read(
          sessionDetailProvider(sessionId(1)).future,
        );
        final reads = repository.fetchCalls + repository.bookingFetches.length;

        await container
            .read(sessionCommandsProvider)
            .updateAddress(loaded!.session, 'Via Pignolo 5, Bergamo');

        expect(repository.addressUpdates, [
          (testClientId, 'Via Pignolo 5, Bergamo'),
        ]);
        for (final session in window()) {
          expect(
            session.address,
            session.clientId == testClientId
                ? 'Via Pignolo 5, Bergamo'
                : isNull,
            reason: session.id,
          );
        }
        final open = container.read(sessionDetailProvider(sessionId(1))).value!;
        expect(open.session.address, 'Via Pignolo 5, Bergamo');
        expect(
          open.booking.map((s) => s.address).toSet(),
          {'Via Pignolo 5, Bergamo'},
        );
        expect(
          repository.fetchCalls + repository.bookingFetches.length,
          reads,
        );
        // El aviso del cambio no imprime la dirección.
        expect(
          container.read(sessionChangesProvider).toString(),
          isNot(contains('Pignolo')),
        );
      },
    );

    test('si no se pudo guardar no cambia nada y relanza SessionFailure', () async {
      await start();
      repository.addressFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      await expectLater(
        container
            .read(sessionCommandsProvider)
            .updateAddress(window().first, 'Via Pignolo 5, Bergamo'),
        throwsA(isA<SessionFailure>()),
      );
      expect(window().first.address, 'Via Gombito 12, 24129 Bergamo');
      expect(container.read(sessionChangesProvider), isNull);
    });
  });

  group('ficha de la sesión', () {
    Future<SessionDetail?> detail(String id) {
      container.listen(sessionDetailProvider(id), (_, _) {});
      return container.read(sessionDetailProvider(id).future);
    }

    test('desde la agenda: una sola lectura, la de su reserva', () async {
      await start();
      final loaded = await detail(sessionId(2));

      expect(loaded!.session.id, sessionId(2));
      expect(loaded.booking, hasLength(4));
      expect(loaded.position, (week: 2, weeks: 4));
      expect(loaded.following.map((s) => s.id), [sessionId(3), sessionId(4)]);
      expect(loaded.endOfBooking, CalendarDate(2026, 12, 23));
      expect(repository.bookingFetches, [bookingRequestId]);
      expect(repository.sessionFetches, isEmpty);
    });

    test(
      'con un enlace directo (sin la agenda): la sesión y después su reserva',
      () async {
        await start(agenda: false);
        final loaded = await detail(sessionId(3));

        expect(loaded!.position, (week: 3, weeks: 4));
        expect(repository.sessionFetches, [sessionId(3)]);
        expect(repository.bookingFetches, [bookingRequestId]);
        expect(repository.fetchCalls, 0, reason: 'no lee la agenda');
      },
    );

    test('una que no existe da null; una sin reserva, ella sola', () async {
      final alone = buildSession(n: 7, requestId: null);
      repository.sessions[alone.id] = alone;
      await start(agenda: false);

      expect(await detail(sessionId(42)), isNull);
      final loaded = await detail(alone.id);
      expect(loaded!.booking.single.id, alone.id);
      expect(loaded.position, isNull);
      expect(repository.bookingFetches, isEmpty);
    });

    test(
      'mover y cancelar desde otra pantalla se ven en la ficha abierta',
      () async {
        await start();
        final loaded = await detail(sessionId(1));
        final commands = container.read(sessionCommandsProvider);

        await commands.move(
          loaded!.booking[3],
          date: CalendarDate(2026, 12, 18),
          start: const ClockTime.hm(10, 0),
        );
        await commands.cancel([loaded.booking[1]]);

        final current = container
            .read(sessionDetailProvider(sessionId(1)))
            .value!;
        expect(
          current.booking.firstWhere((s) => s.id == sessionId(4)).date,
          CalendarDate(2026, 12, 18),
        );
        expect(current.position, (week: 1, weeks: 3));
        expect(current.following.map((s) => s.id), [
          sessionId(3),
          sessionId(4),
        ]);
      },
    );

    test('volver a leer: si falla, queda lo que había y avisa', () async {
      await start();
      await detail(sessionId(1));
      repository.fetchFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      final notifier = container.read(
        sessionDetailProvider(sessionId(1)).notifier,
      );
      await expectLater(notifier.reload(), throwsA(isA<SessionFailure>()));
      expect(
        container.read(sessionDetailProvider(sessionId(1))).value?.session.id,
        sessionId(1),
      );
      await notifier.reloadQuietly();
    });
  });

  test('después de una reserva nueva, la agenda vuelve a leer solo si ya estaba cargada', () async {
    await start(agenda: false);
    final probe = Provider<Future<void> Function()?>(agendaSessionsRefresher);
    expect(container.read(probe), isNull);
    expect(repository.fetchCalls, 0);

    container.listen(sessionsControllerProvider, (_, _) {});
    await pumpEventQueue();
    container.invalidate(probe);
    await container.read(probe)!();
    expect(repository.fetchCalls, 2);
  });
}

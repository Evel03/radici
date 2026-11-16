// Hoja «Mover la sesión» sin widgets: el dryRun antes de confirmar, los
// avisos, el choque, la semana que ya tiene otra sesión de la reserva (con
// «Pasar al final de la reserva»), confirmar y lo que devuelve para
// «Deshacer». La reserva de prueba: miércoles 25/11, 2/12, 9/12 y 16/12.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/sessions/application/move_session_controller.dart';
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
  late ProviderContainer container;
  late MoveSessionArgs args;

  final thursday = CalendarDate(2026, 12, 3);

  MoveSessionState state() => container.read(moveSessionProvider(args));
  MoveSessionController controller() =>
      container.read(moveSessionProvider(args).notifier);

  /// Abre la hoja de la sesión [n] (con la ficha ya cargada, como la
  /// pantalla), con [date] elegida o sin fecha.
  Future<void> open({int n = 2, CalendarDate? date}) async {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: chefUser),
        ),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        sessionsRepositoryProvider.overrideWithValue(repository),
        clockProvider.overrideWithValue(() => testNow),
      ],
    );
    // La cuenta de la cocinera ya cargada, como en la app (el router no deja
    // abrir la ficha antes).
    container.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
    final id = sessionId(n);
    container.listen(sessionDetailProvider(id), (_, _) {});
    await container.read(sessionDetailProvider(id).future);
    args = (sessionId: id, date: date);
    container.listen(moveSessionProvider(args), (_, _) {});
    await pumpEventQueue();
  }

  setUp(() {
    repository = FakeSessionsRepository(buildBooking());
  });

  test(
    'con la fecha elegida pide el dryRun con la hora de ahora y deja mover',
    () async {
      await open(date: thursday);

      expect(
        repository.checks.single,
        MoveSessionRequest(
          sessionId: sessionId(2),
          date: thursday,
          start: const ClockTime.hm(10, 0),
          dryRun: true,
        ),
      );
      expect(state().checksStatus, MoveChecksStatus.ready);
      expect(state().currentCheck?.status, BookingDayStatus.ok);
      expect(state().suggestedStart, const ClockTime.hm(10, 0));
      expect(state().blocker, isNull);
      expect(state().canConfirm, isTrue);
    },
  );

  test(
    'sin fecha elegida no pide nada: hay que elegir otra fecha u hora',
    () async {
      await open();
      expect(repository.checks, isEmpty);
      expect(state().changed, isFalse);
      expect(state().blocker, MoveBlocker.unchanged);
      expect(state().canConfirm, isFalse);

      // Solo otra hora, el mismo día, también es mover.
      controller().setStart(const ClockTime.hm(11, 30));
      await pumpEventQueue();
      expect(repository.checks.single.date, CalendarDate(2026, 12, 2));
      expect(repository.checks.single.start, const ClockTime.hm(11, 30));
      expect(state().canConfirm, isTrue);
    },
  );

  test('un aviso (día bloqueado) no impide moverla; un choque sí', () async {
    repository.statuses[thursday] = BookingDayStatus.blocked;
    repository.statuses[thursday.addDays(1)] = BookingDayStatus.busy;
    await open(date: thursday);
    expect(state().currentCheck?.status, BookingDayStatus.blocked);
    expect(state().canConfirm, isTrue);

    controller().setDate(thursday.addDays(1));
    await pumpEventQueue();
    expect(state().clash, isTrue);
    expect(state().blocker, MoveBlocker.clash);
    expect(state().canConfirm, isFalse);
  });

  test('una semana con otra sesión de la reserva: no deja moverla y ofrece el final de la reserva', () async {
    // La semana 2 al jueves 10/12, la semana de la 3.
    await open(date: CalendarDate(2026, 12, 10));
    expect(state().weekTaken, isTrue);
    expect(state().blocker, MoveBlocker.weekTaken);
    expect(state().canConfirm, isFalse);
    expect(state().endOfBooking, CalendarDate(2026, 12, 23));

    controller().moveToEnd();
    await pumpEventQueue();
    expect(state().date, CalendarDate(2026, 12, 23));
    expect(repository.checks.last.date, CalendarDate(2026, 12, 23));
    expect(state().weekTaken, isFalse);
    expect(state().canConfirm, isTrue);
  });

  test('la última semana no tiene final al que pasarla', () async {
    await open(n: 4, date: CalendarDate(2026, 12, 10));
    expect(state().weekTaken, isTrue);
    expect(state().endOfBooking, isNull);
  });

  test(
    'mover: la sesión movida, con la fecha y la hora de antes para «Deshacer»',
    () async {
      await open(date: thursday);
      controller().setStart(const ClockTime.hm(11, 0));
      await pumpEventQueue();

      await controller().confirm();

      expect(
        repository.moves.single,
        MoveSessionRequest(
          sessionId: sessionId(2),
          date: thursday,
          start: const ClockTime.hm(11, 0),
        ),
      );
      final outcome = state().outcome!;
      expect(outcome.moved.date, thursday);
      expect(outcome.moved.start, const ClockTime.hm(11, 0));
      expect(outcome.previousDate, CalendarDate(2026, 12, 2));
      expect(outcome.previousStart, const ClockTime.hm(10, 0));
      // La ficha abierta ya lo muestra.
      expect(
        container.read(sessionDetailProvider(sessionId(2))).value?.session.date,
        thursday,
      );
      // Ya movida, la hoja no cambia.
      controller().setDate(thursday.addDays(1));
      expect(state().date, thursday);
      expect(state().canConfirm, isFalse);
    },
  );

  test('mientras mueve no se puede volver a mandar ni cambiar nada', () async {
    await open(date: thursday);
    repository.pendingMove = Completer<void>();
    final first = controller().confirm();
    await pumpEventQueue();
    expect(state().sending, isTrue);
    expect(state().canConfirm, isFalse);
    await controller().confirm();
    controller().setDate(thursday.addDays(1));
    expect(state().date, thursday);

    repository.pendingMove!.complete();
    await first;
    expect(repository.moves, hasLength(1));
  });

  test('si al mover choca, lo dice y el dryRun marca por qué', () async {
    await open(date: thursday);
    repository.statuses[thursday] = BookingDayStatus.busy;

    await controller().confirm();
    await pumpEventQueue();

    expect(state().failure?.kind, SessionFailureKind.slotTaken);
    expect(state().failure?.date, thursday);
    expect(state().clash, isTrue);
    expect(state().outcome, isNull);
  });

  test(
    'sin respuesta se puede reintentar: mover a la misma fecha no duplica nada',
    () async {
      await open(date: thursday);
      repository.moveFailure = const SessionFailure(
        SessionFailureKind.unavailable,
      );
      await controller().confirm();
      expect(state().failure?.kind, SessionFailureKind.unavailable);
      expect(state().canConfirm, isTrue);

      repository.moveFailure = null;
      await controller().confirm();
      expect(state().outcome?.moved.date, thursday);
      expect(state().failure, isNull);
    },
  );

  test('si la sesión ya no se puede mover (otro dispositivo), la hoja se bloquea y la ficha se relee', () async {
    await open(date: thursday);
    repository.sessions[sessionId(2)] = repository.sessions[sessionId(2)]!
        .copyWith(status: SessionStatus.cooked);
    final reads = repository.bookingFetches.length;

    await controller().confirm();
    await pumpEventQueue();

    expect(state().failure?.kind, SessionFailureKind.notMovable);
    expect(state().failure?.status, SessionStatus.cooked);
    expect(state().blocked, isTrue);
    expect(state().canConfirm, isFalse);
    expect(repository.bookingFetches.length, reads + 1);
  });

  test('una sesión cocinada abre la hoja ya bloqueada', () async {
    repository.sessions[sessionId(1)] = repository.sessions[sessionId(1)]!
        .copyWith(status: SessionStatus.cooked);
    await open(n: 1, date: thursday);
    expect(state().failure?.kind, SessionFailureKind.notMovable);
    expect(state().blocked, isTrue);
    expect(repository.checks, isEmpty);
  });

  test('si el dryRun falla se puede mover igual y reintentarlo', () async {
    repository.checkFailure = const SessionFailure(
      SessionFailureKind.unavailable,
    );
    await open(date: thursday);
    expect(state().checksStatus, MoveChecksStatus.failed);
    expect(state().canConfirm, isTrue);

    repository.checkFailure = null;
    controller().retryChecks();
    await pumpEventQueue();
    expect(state().checksStatus, MoveChecksStatus.ready);
  });

  test('solo vale la respuesta del último dryRun', () async {
    await open();
    final slow = Completer<void>();
    repository.pendingCheck = slow;
    repository.statuses[thursday] = BookingDayStatus.busy;
    controller().setDate(thursday);
    await pumpEventQueue();

    repository.pendingCheck = null;
    controller().setDate(thursday.addDays(1));
    await pumpEventQueue();
    expect(state().currentCheck?.date, thursday.addDays(1));

    slow.complete();
    await pumpEventQueue();
    expect(state().date, thursday.addDays(1));
    expect(state().currentCheck?.date, thursday.addDays(1));
    expect(state().clash, isFalse);
  });
}

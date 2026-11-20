// «Rinnova» en la ficha de la sesión, sin widgets (decisión 3): la fila va en
// la última sesión viva de una reserva semanal, sin depender de la agenda
// (también con dos reservas en paralelo de la misma ficha, o con la agenda
// cargando o con error), y la línea «Ha già un'altra sessione…» dice la
// próxima sesión viva de la ficha: de la agenda leída (nunca de una lista
// vacía en su lugar) o de una renovación hecha desde este dispositivo.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/renewed_bookings.dart';
import 'package:radici/features/sessions/application/session_renewal.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  // La reserva de prueba: miércoles 25/11, 2/12, 9/12 y 16/12. Hoy: 19/10.
  late FakeSessionsRepository sessions;
  late ProviderContainer container;

  setUp(() async {
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
        sessionsRepositoryProvider.overrideWithValue(sessions),
        clockProvider.overrideWithValue(() => testNow),
      ],
    );
    container.listen(currentChefProvider, (_, _) {});
    await pumpEventQueue();
  });

  void save(Iterable<CookingSession> list) {
    for (final session in list) {
      sessions.sessions[session.id] = session;
    }
  }

  /// La ficha de la sesión [n], ya leída.
  Future<void> openDetail(int n) async {
    container.listen(sessionDetailProvider(sessionId(n)), (_, _) {});
    await pumpEventQueue();
    expect(container.read(sessionDetailProvider(sessionId(n))).hasValue, isTrue);
  }

  bool offered(int n) =>
      container.read(sessionRenewalOfferProvider(sessionId(n)));

  CalendarDate? later(int n) =>
      container.read(sessionLaterSessionProvider(sessionId(n)));

  /// Otra reserva de la misma ficha, del 23/12 al 13/1.
  List<CookingSession> renewal() => buildBooking(
    first: CalendarDate(2026, 12, 23),
    firstN: 10,
    requestId: 'renovacion',
  );

  group('dónde va «Rinnova»', () {
    test('en la última sesión viva de una reserva semanal; no en otra semana', () async {
      save(buildBooking());
      await openDetail(4);
      await openDetail(2);
      expect(offered(4), isTrue);
      expect(offered(2), isFalse);
    });

    test('también si la agenda tiene una sesión viva posterior de la misma ficha (dos reservas en paralelo)', () async {
      save([...buildBooking(), ...renewal()]);
      container.listen(sessionsControllerProvider, (_, _) {});
      await pumpEventQueue();
      await openDetail(4);
      expect(offered(4), isTrue);
    });

    test('no depende de la agenda: también mientras carga o si no se pudo leer', () async {
      save(buildBooking());
      await openDetail(4);
      sessions.pendingFetch = Completer<void>();
      container.listen(sessionsControllerProvider, (_, _) {});
      await pumpEventQueue();
      expect(container.read(sessionsControllerProvider).isLoading, isTrue);
      expect(offered(4), isTrue);

      sessions.fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
      sessions.pendingFetch!.complete();
      await pumpEventQueue();
      expect(container.read(sessionsControllerProvider).hasError, isTrue);
      expect(offered(4), isTrue);
    });

    test('ni en una semana cancelada, ni en una sesión extra, ni con la ficha sin leer', () async {
      save([
        ...buildBooking(statuses: {4: SessionStatus.cancelled}),
        buildSession(n: 7, requestId: 'extra', type: RequestType.extra),
      ]);
      expect(offered(4), isFalse, reason: 'todavía no se leyó');
      await openDetail(4);
      await openDetail(7);
      expect(offered(4), isFalse);
      expect(offered(7), isFalse);
      expect(offered(3), isFalse, reason: 'sin escucharla, no se lee');
    });
  });

  group('«Ha già un\'altra sessione…»', () {
    test('con la agenda leída, la fecha de la próxima sesión viva de la ficha', () async {
      save([...buildBooking(), ...renewal()]);
      await openDetail(4);
      container.listen(sessionLaterSessionProvider(sessionId(4)), (_, _) {});
      await pumpEventQueue();
      expect(later(4), CalendarDate(2026, 12, 23));
    });

    test('mientras la agenda carga, null; cuando llega, la fecha', () async {
      save([...buildBooking(), ...renewal()]);
      await openDetail(4);
      sessions.pendingFetch = Completer<void>();
      container.listen(sessionLaterSessionProvider(sessionId(4)), (_, _) {});
      await pumpEventQueue();
      expect(container.read(sessionsControllerProvider).isLoading, isTrue);
      expect(later(4), isNull);

      sessions.pendingFetch!.complete();
      await pumpEventQueue();
      expect(later(4), CalendarDate(2026, 12, 23));
    });

    test('sin sesión posterior en la agenda, la primera fecha de una renovación hecha desde este dispositivo', () async {
      save(buildBooking());
      await openDetail(4);
      container.listen(sessionLaterSessionProvider(sessionId(4)), (_, _) {});
      await pumpEventQueue();
      expect(later(4), isNull);
      container
          .read(renewedBookingsProvider.notifier)
          .mark(bookingRequestId, CalendarDate(2026, 12, 23));
      expect(later(4), CalendarDate(2026, 12, 23));
    });

    test('si la agenda no se pudo leer, null; con una renovación hecha desde este dispositivo, su primera fecha', () async {
      // En la base hay una sesión posterior, pero la agenda no se pudo leer.
      save([...buildBooking(), ...renewal()]);
      await openDetail(4);
      sessions.fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
      container.listen(sessionLaterSessionProvider(sessionId(4)), (_, _) {});
      await pumpEventQueue();
      expect(container.read(sessionsControllerProvider).hasError, isTrue);
      expect(later(4), isNull);

      container
          .read(renewedBookingsProvider.notifier)
          .mark(bookingRequestId, CalendarDate(2026, 12, 30));
      expect(later(4), CalendarDate(2026, 12, 30));
    });
  });
}

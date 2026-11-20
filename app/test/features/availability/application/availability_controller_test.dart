// Disponibilidad de la cocinera: carga, bloquear y desbloquear con «Deshacer»
// (se ve enseguida y vuelve atrás si falla), rangos, notas, otro dispositivo
// y lo que la agenda muestra de cada día. "Hoy": lunes 19/10/2026 (testNow).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/availability/application/availability_controller.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeAvailabilityRepository repository;
  late FakeChefRequestsRepository requests;
  late FakeSessionsRepository sessions;
  late ProviderContainer container;

  final wednesday = CalendarDate(2026, 10, 21);
  final thursday = CalendarDate(2026, 10, 22);
  final friday = CalendarDate(2026, 10, 23);
  final saturday = CalendarDate(2026, 10, 24);

  AvailabilitySnapshot snapshot() =>
      container.read(availabilityControllerProvider).requireValue;
  AvailabilityController controller() =>
      container.read(availabilityControllerProvider.notifier);
  Set<CalendarDate> saving() => container.read(availabilitySavingProvider);

  Future<void> start() async {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        availabilityRepositoryProvider.overrideWithValue(repository),
        chefRequestsRepositoryProvider.overrideWithValue(requests),
        sessionsRepositoryProvider.overrideWithValue(sessions),
        clockProvider.overrideWithValue(() => testNow),
      ],
    );
    // Como en la agenda: algo la escucha todo el tiempo.
    container.listen(availabilityControllerProvider, (_, _) {});
    await pumpEventQueue();
  }

  setUp(() {
    auth = FakeAuthRepository(user: chefUser);
    repository = FakeAvailabilityRepository();
    requests = FakeChefRequestsRepository([
      buildRequest(id: 'a', preferredDate: wednesday),
      buildRequest(id: 'b', preferredDate: wednesday),
      buildRequest(id: 'c', preferredDate: wednesday, status: RequestStatus.rejected),
    ]);
    // El miércoles, una sesión confirmada y otra cancelada.
    sessions = FakeSessionsRepository([
      buildSession(n: 1, date: wednesday),
      buildSession(
        n: 2,
        date: wednesday,
        start: const ClockTime.hm(14, 0),
        status: SessionStatus.cancelled,
      ),
    ]);
  });

  group('carga', () {
    test('el horario y los bloqueos desde el lunes de la primera semana del mes', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday, note: 'Ferie');
      await start();

      expect(snapshot().rules, weekdayRules());
      expect(snapshot().blocked, {
        friday: BlockedDay(id: 'b1', date: friday, note: 'Ferie'),
      });
      expect(repository.fetchedFrom, [CalendarDate(2026, 9, 28)]);
    });

    test('sin sesión de cocinera queda vacía y no llama al servidor', () async {
      auth = FakeAuthRepository();
      await start();
      expect(snapshot(), AvailabilitySnapshot.empty);
      expect(repository.fetchCalls, 0);
    });

    test('un error al cargar queda como AsyncError; invalidar reintenta', () async {
      repository.failFetch = true;
      await start();
      expect(container.read(availabilityControllerProvider).hasError, isTrue);

      repository.failFetch = false;
      container.invalidate(availabilityControllerProvider);
      await pumpEventQueue();
      expect(snapshot().rules, weekdayRules());
    });
  });

  group('bloquear', () {
    test('se ve bloqueado y "guardando" antes de que responda; después queda con su id', () async {
      await start();
      repository.pendingBlock = Completer<void>();

      final pending = controller().block([wednesday], note: '  Ferie ');
      await pumpEventQueue();
      expect(snapshot().blocked[wednesday], BlockedDay(date: wednesday, note: 'Ferie'));
      expect(saving(), {wednesday});

      repository.pendingBlock!.complete();
      final created = await pending;
      expect(created, hasLength(1));
      expect(created.single.id, isNotNull);
      expect(snapshot().blocked[wednesday], created.single);
      expect(saving(), isEmpty);
      expect(repository.blockCalls.single, [(date: wednesday, note: 'Ferie')]);
    });

    test('si falla, vuelve atrás y lanza AvailabilityFailure', () async {
      await start();
      repository.failBlock = true;

      await expectLater(
        controller().block([wednesday]),
        throwsA(isA<AvailabilityFailure>()),
      );
      expect(snapshot().blocked, isEmpty);
      expect(saving(), isEmpty);
    });

    test('un rango manda solo los días que faltan; los ya bloqueados no cambian', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday, note: 'Ferie');
      await start();

      final created = await controller().block(
        datesInRange(wednesday, saturday),
        note: 'Vacanze',
      );

      expect(repository.blockCalls.single.map((d) => d.date), [
        wednesday,
        thursday,
        saturday,
      ]);
      expect(created.map((b) => b.date), [wednesday, thursday, saturday]);
      expect(snapshot().blocked[friday]!.note, 'Ferie');
      expect(snapshot().blocked[saturday]!.note, 'Vacanze');
    });

    test('bloquear un día que ya está bloqueado no llama al servidor', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday);
      await start();
      expect(await controller().block([friday]), isEmpty);
      expect(repository.blockCalls, isEmpty);
    });

    test('si otro dispositivo ya lo había bloqueado, el día queda bloqueado igual y «Deshacer» quita solo lo creado', () async {
      await start();
      // Mientras tanto, desde el teléfono:
      repository.blocked[friday] = BlockedDay(
        id: 'del-telefono',
        date: friday,
        note: 'Dentista',
      );

      final created = await controller().block([wednesday, friday]);
      expect(created.map((b) => b.date), [wednesday]);
      expect(snapshot().blocked.keys, containsAll([wednesday, friday]));
      // Se vuelve a leer para tener el bloqueo del otro dispositivo, con su nota.
      await pumpEventQueue();
      expect(snapshot().blocked[friday], repository.blocked[friday]);

      await controller().undoBlock(created);
      expect(repository.unblockCalls.single, [created.single.id]);
      expect(snapshot().blocked.keys, [friday]);
      expect(repository.blocked.keys, [friday]);
    });

    test('«Deshacer» quita por id: no toca otro bloqueo del mismo día', () async {
      await start();
      final created = await controller().block([wednesday]);
      // Desde otro dispositivo lo desbloquearon y lo volvieron a bloquear.
      repository.blocked[wednesday] = BlockedDay(
        id: 'otro',
        date: wednesday,
        note: 'Dentista',
      );
      await controller().refresh();

      await controller().undoBlock(created);
      // Manda el id que creó (ya no existe: no hace nada), nunca el del otro.
      expect(repository.unblockCalls.single, [created.single.id]);
      expect(repository.blocked[wednesday]?.id, 'otro');
      expect(snapshot().blocked[wednesday]?.id, 'otro');
    });
  });

  group('desbloquear', () {
    test('se ve enseguida, devuelve lo quitado y «Deshacer» vuelve a crear la nota', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday, note: 'Ferie');
      await start();
      repository.pendingUnblock = Completer<void>();

      final pending = controller().unblock([friday]);
      await pumpEventQueue();
      expect(snapshot().blocked, isEmpty);
      expect(saving(), {friday});

      repository.pendingUnblock!.complete();
      final removed = await pending;
      expect(removed, [BlockedDay(id: 'b1', date: friday, note: 'Ferie')]);
      expect(repository.unblockCalls.single, ['b1']);
      expect(saving(), isEmpty);

      await controller().undoUnblock(removed);
      expect(repository.blockCalls.single, [(date: friday, note: 'Ferie')]);
      expect(snapshot().blocked[friday]!.note, 'Ferie');
      expect(repository.blocked[friday]!.note, 'Ferie');
    });

    test('«Deshacer» un rango con notas distintas manda cada una en un solo pedido', () async {
      repository.blocked
        ..[thursday] = BlockedDay(id: 'b1', date: thursday, note: 'Ferie')
        ..[friday] = BlockedDay(id: 'b2', date: friday);
      await start();

      final removed = await controller().unblock(datesInRange(wednesday, saturday));
      expect(removed.map((b) => b.id), ['b1', 'b2']);
      await controller().undoUnblock(removed);

      expect(repository.blockCalls.single, [
        (date: thursday, note: 'Ferie'),
        (date: friday, note: null),
      ]);
    });

    test('si falla, el día vuelve a quedar bloqueado con su nota y lanza', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday, note: 'Ferie');
      await start();
      repository.failUnblock = true;

      await expectLater(
        controller().unblock([friday]),
        throwsA(isA<AvailabilityFailure>()),
      );
      expect(snapshot().blocked[friday], BlockedDay(id: 'b1', date: friday, note: 'Ferie'));
      expect(saving(), isEmpty);
    });

    test('un día abierto no se desbloquea ni llama al servidor', () async {
      await start();
      expect(await controller().unblock([wednesday]), isEmpty);
      expect(repository.unblockCalls, isEmpty);
    });
  });

  group('nota', () {
    test('cambia la nota (recortada); vacía la borra', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday);
      await start();

      await controller().setNote(friday, ' Vacanze ');
      expect(snapshot().blocked[friday]!.note, 'Vacanze');
      expect(repository.noteCalls.last, (id: 'b1', note: 'Vacanze'));

      await controller().setNote(friday, '   ');
      expect(snapshot().blocked[friday]!.note, isNull);
      expect(repository.noteCalls.last, (id: 'b1', note: null));
    });

    test('guardar la misma nota no llama al servidor', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday, note: 'Ferie');
      await start();
      await controller().setNote(friday, ' Ferie ');
      expect(repository.noteCalls, isEmpty);
    });

    test('si falla, vuelve la nota anterior y lanza', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday, note: 'Ferie');
      await start();
      repository.failNote = true;

      await expectLater(
        controller().setNote(friday, 'Vacanze'),
        throwsA(isA<AvailabilityFailure>()),
      );
      expect(snapshot().blocked[friday]!.note, 'Ferie');
    });

    test('si el bloqueo ya no existe, vuelve a leer y lanza notFound', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday, note: 'Ferie');
      await start();
      // Desde otro dispositivo lo desbloquearon.
      repository.blocked.remove(friday);

      await expectLater(
        controller().setNote(friday, 'Vacanze'),
        throwsA(
          isA<AvailabilityFailure>().having(
            (f) => f.kind,
            'kind',
            AvailabilityFailureKind.notFound,
          ),
        ),
      );
      await pumpEventQueue();
      expect(snapshot().blocked, isEmpty);
    });
  });

  group('refresh', () {
    test('vuelve a leer lo del servidor', () async {
      await start();
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday);
      await controller().refresh();
      expect(snapshot().blocked.keys, [friday]);
    });

    test('si falla, queda lo que había y lanza', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday);
      await start();
      repository.failFetch = true;
      await expectLater(controller().refresh(), throwsA(isA<AvailabilityFailure>()));
      expect(snapshot().blocked.keys, [friday]);
    });
  });

  // El repositorio falso toma la foto cuando llega la lectura, como la base;
  // pendingFetch demora solo la respuesta (una red lenta).
  group('una lectura que se cruza con un cambio', () {
    test('bloquear mientras se lee: la foto vieja no lo borra y «Deshacer» lo quita', () async {
      await start();
      repository.pendingFetch = Completer<void>();
      final reading = controller().refresh(); // foto sin el miércoles
      await pumpEventQueue();

      final created = await controller().block([wednesday]);
      repository.pendingFetch!.complete();
      await reading;

      expect(snapshot().blocked[wednesday], created.single);
      expect(repository.fetchCalls, 3, reason: 'la carga, la descartada y otra');
      await controller().undoBlock(created);
      expect(repository.unblockCalls.single, [created.single.id]);
      expect(repository.blocked, isEmpty);
      expect(snapshot().blocked, isEmpty);
    });

    test('desbloquear mientras se lee: la foto vieja no lo vuelve a mostrar y «Deshacer» lo vuelve a bloquear', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday, note: 'Ferie');
      await start();
      repository.pendingFetch = Completer<void>();
      final reading = controller().refresh(); // foto con el viernes
      await pumpEventQueue();

      final removed = await controller().unblock([friday]);
      repository.pendingFetch!.complete();
      await reading;
      expect(snapshot().blocked, isEmpty);
      expect(repository.blocked, isEmpty);

      await controller().undoUnblock(removed);
      expect(repository.blockCalls.single, [(date: friday, note: 'Ferie')]);
      expect(repository.blocked[friday]?.note, 'Ferie');
      expect(snapshot().blocked[friday]?.note, 'Ferie');
    });

    test('cambiar la nota mientras se lee: queda la nueva', () async {
      repository.blocked[friday] = BlockedDay(id: 'b1', date: friday, note: 'Ferie');
      await start();
      repository.pendingFetch = Completer<void>();
      final reading = controller().refresh(); // foto con 'Ferie'
      await pumpEventQueue();

      await controller().setNote(friday, 'Dentista');
      repository.pendingFetch!.complete();
      await reading;
      expect(snapshot().blocked[friday]?.note, 'Dentista');
      expect(repository.blocked[friday]?.note, 'Dentista');
    });

    test('«Deshacer» un bloqueo a medias antes de que vuelva la relectura: queda como en el servidor', () async {
      await start();
      // Desde el teléfono, sin que este dispositivo lo sepa:
      repository.blocked[friday] = BlockedDay(
        id: 'del-telefono',
        date: friday,
        note: 'Dentista',
      );
      repository.pendingFetch = Completer<void>();

      final created = await controller().block([wednesday, friday]);
      // La relectura (para tener la fila del viernes) ya tomó su foto, con
      // el miércoles; «Deshacer» llega antes que la respuesta.
      await pumpEventQueue();
      await controller().undoBlock(created);
      repository.pendingFetch!.complete();
      await pumpEventQueue();

      expect(repository.blocked.keys, [friday]);
      expect(snapshot().blocked.keys, [friday]);
      expect(snapshot().blocked[friday], repository.blocked[friday]);
    });

    test('si las dos lecturas se cruzan con un cambio, queda lo local', () async {
      await start();
      repository.pendingBlock = Completer<void>();
      final blocking = controller().block([wednesday]); // espera al servidor
      await pumpEventQueue();

      await controller().refresh();
      expect(repository.fetchCalls, 3, reason: 'la carga y dos lecturas descartadas');
      expect(snapshot().blocked[wednesday], BlockedDay(date: wednesday));

      repository.pendingBlock!.complete();
      final created = await blocking;
      expect(snapshot().blocked[wednesday], created.single);
    });
  });

  group('un bloqueo de otro dispositivo que no se pudo leer', () {
    // El viernes ya estaba bloqueado desde el teléfono y la relectura falló
    // (sin señal): queda bloqueado, pero sin id.
    Future<void> blockedFromPhoneWithoutId() async {
      await start();
      repository.blocked[friday] = BlockedDay(
        id: 'del-telefono',
        date: friday,
        note: 'Dentista',
      );
      repository.failFetch = true;
      expect(await controller().block([friday]), isEmpty);
      await pumpEventQueue();
      expect(snapshot().blocked[friday], BlockedDay(date: friday));
      expect(saving(), isEmpty);
      repository.failFetch = false;
    }

    test('«Sblocca» primero lo lee y lo quita por su id', () async {
      await blockedFromPhoneWithoutId();
      final removed = await controller().unblock([friday]);
      expect(removed, [BlockedDay(id: 'del-telefono', date: friday, note: 'Dentista')]);
      expect(repository.unblockCalls.single, ['del-telefono']);
      expect(snapshot().blocked, isEmpty);
    });

    test('si la relectura vuelve a fallar, «Sblocca» lanza (para «Riprova») y no borra nada', () async {
      await blockedFromPhoneWithoutId();
      repository.failFetch = true;
      await expectLater(
        controller().unblock([friday]),
        throwsA(isA<AvailabilityFailure>()),
      );
      expect(repository.unblockCalls, isEmpty);
      expect(snapshot().blocked.keys, [friday]);
    });

    test('guardar la nota primero lo lee y la guarda en su fila', () async {
      await blockedFromPhoneWithoutId();
      await controller().setNote(friday, 'Ferie');
      expect(repository.noteCalls.single, (id: 'del-telefono', note: 'Ferie'));
      expect(snapshot().blocked[friday]?.note, 'Ferie');
    });

    test('si esa lectura se cruza con otro cambio, «Sblocca» y la nota lanzan (para «Riprova») sin tocar nada', () async {
      await blockedFromPhoneWithoutId();
      repository.pendingBlock = Completer<void>();
      final blocking = controller().block([wednesday]); // espera al servidor
      await pumpEventQueue();

      await expectLater(
        controller().unblock([friday]),
        throwsA(isA<AvailabilityFailure>()),
      );
      await expectLater(
        controller().setNote(friday, 'Ferie'),
        throwsA(isA<AvailabilityFailure>()),
      );
      expect(repository.unblockCalls, isEmpty);
      expect(repository.noteCalls, isEmpty);
      expect(snapshot().blocked[friday], BlockedDay(date: friday));

      repository.pendingBlock!.complete();
      await blocking;
      // Ya sin cambios en curso, se lee y se quita por su id.
      expect(await controller().unblock([friday]), hasLength(1));
      expect(repository.unblockCalls.single, ['del-telefono']);
    });
  });

  group('agendaDayAvailabilityProvider', () {
    test('null mientras carga', () async {
      repository.pendingFetch = Completer<void>();
      await start();
      expect(container.read(agendaDayAvailabilityProvider(wednesday)), isNull);
      repository.pendingFetch!.complete();
      await pumpEventQueue();
      expect(container.read(agendaDayAvailabilityProvider(wednesday)), isNotNull);
    });

    test('combina la foto, hoy, el feriado, los pedidos activos y las sesiones vivas de ese día', () async {
      await start();
      container.listen(agendaDayAvailabilityProvider(wednesday), (_, _) {});
      await pumpEventQueue();

      final day = container.read(agendaDayAvailabilityProvider(wednesday))!;
      expect(day.status, DayStatus.open);
      expect(day.requestCount, 2, reason: 'el rechazado no cuenta');
      expect(day.sessionCount, 1, reason: 'la cancelada no cuenta');
      expect(day.hours.single.weekday, DateTime.wednesday);
      expect(sessions.fetchCalls, 1);

      final immaculate = container.read(
        agendaDayAvailabilityProvider(CalendarDate(2026, 12, 8)),
      )!;
      expect(immaculate.holiday, ItalianHoliday.immaculate);
      expect(immaculate.sessionCount, 0);

      // Bloquear el día no cancela sus sesiones.
      await controller().block([wednesday]);
      final blocked = container.read(agendaDayAvailabilityProvider(wednesday))!;
      expect(blocked.status, DayStatus.blocked);
      expect(blocked.sessionCount, 1);
    });
  });
}

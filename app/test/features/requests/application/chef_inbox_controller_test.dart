// Lista de pedidos de la cocinera: carga, tiempo real (el aviso, solo para
// los pedidos de la web sin abrir; uno de la app, como una reserva a mano, se
// suma sin aviso), reconexión, "visto" y rechazo, con repositorios falsos.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/application/new_request_alert.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeChefRequestsRepository repository;
  late ProviderContainer container;

  final older = buildRequest(
    id: 'older',
    seenAt: DateTime.utc(2026, 10, 18),
    createdAt: DateTime.utc(2026, 10, 18, 9),
  );
  final fresh = buildRequest(id: 'fresh', createdAt: DateTime.utc(2026, 10, 19, 9));

  /// Una reserva cargada a mano, como la crea chef_create_booking: pedido de
  /// la app, aceptado y visto, sin fecha preferida ni estimación.
  ChefRequest manualBooking(String id, DateTime createdAt) => buildRequest(
    id: id,
    source: RequestSource.app,
    status: RequestStatus.accepted,
    seenAt: createdAt,
    createdAt: createdAt,
    noDate: true,
    estimate: null,
  );

  List<ChefRequest> requests() => container.read(chefInboxProvider).requireValue;
  ChefInboxController controller() => container.read(chefInboxProvider.notifier);
  NewRequestAlert? alert() => container.read(newRequestAlertProvider);

  Future<void> start() async {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        chefRequestsRepositoryProvider.overrideWithValue(repository),
        clockProvider.overrideWithValue(() => testNow),
      ],
    );
    // Como en la app: algo escucha la lista y el aviso todo el tiempo.
    container
      ..listen(chefInboxProvider, (_, _) {})
      ..listen(newRequestAlertProvider, (_, _) {});
    await pumpEventQueue();
  }

  setUp(() {
    auth = FakeAuthRepository(user: chefUser);
    repository = FakeChefRequestsRepository([older, fresh]);
  });

  test('carga los pedidos de la cocinera, del más reciente al más viejo', () async {
    await start();
    expect(requests().map((r) => r.id), ['fresh', 'older']);
    expect(container.read(newRequestsCountProvider), 1);
    expect(repository.realtimeListeners, 1);
  });

  test('sin sesión de cocinera: lista vacía y sin canal', () async {
    auth = FakeAuthRepository();
    await start();
    expect(requests(), isEmpty);
    expect(repository.fetchCalls, 0);
    expect(repository.realtimeListeners, 0);
  });

  test('error al cargar: AsyncError; invalidar reintenta', () async {
    repository.failFetch = true;
    await start();
    expect(container.read(chefInboxProvider).hasError, isTrue);

    repository.failFetch = false;
    container.invalidate(chefInboxProvider);
    await pumpEventQueue();
    expect(requests(), hasLength(2));
  });

  group('tiempo real', () {
    test('un INSERT agrega el pedido y muestra el aviso', () async {
      await start();
      final arrived = buildRequest(
        id: 'arrived',
        name: 'Marco Bianchi',
        createdAt: DateTime.utc(2026, 10, 19, 11),
      );

      repository.insertFromRealtime(arrived);
      await pumpEventQueue();

      expect(requests().first.id, 'arrived');
      expect(container.read(newRequestsCountProvider), 2);
      expect(alert()!.requests.single.client.displayName, 'Marco Bianchi');
    });

    test('un INSERT de un pedido new de la app (sin abrir) se agrega y no avisa', () async {
      await start();
      repository.insertFromRealtime(
        buildRequest(
          id: 'from-app',
          source: RequestSource.app,
          createdAt: DateTime.utc(2026, 10, 19, 11),
        ),
      );
      await pumpEventQueue();

      expect(requests().first.id, 'from-app');
      // Cuenta como nuevo en la bandeja («Nuove» y el contador), pero el aviso
      // emergente es solo para los pedidos de la web.
      expect(inboxTabOf(requests().first), InboxTab.fresh);
      expect(container.read(newRequestsCountProvider), 2);
      expect(alert(), isNull);
    });

    test('una reserva a mano (accepted, source app) que llega por INSERT se agrega a la lista sin aviso', () async {
      await start();
      repository.insertFromRealtime(
        manualBooking('manual', DateTime.utc(2026, 10, 19, 11)),
      );
      await pumpEventQueue();

      expect(requests().first.id, 'manual');
      expect(inboxTabOf(requests().first), InboxTab.bookings);
      expect(container.read(newRequestsCountProvider), 1);
      expect(alert(), isNull);
    });

    test('un pedido de la app no se suma al aviso de uno de la web', () async {
      await start();
      repository
        ..insertFromRealtime(
          buildRequest(id: 'web', createdAt: DateTime.utc(2026, 10, 19, 11)),
        )
        ..insertFromRealtime(
          buildRequest(
            id: 'app',
            source: RequestSource.app,
            createdAt: DateTime.utc(2026, 10, 19, 12),
          ),
        );
      await pumpEventQueue();

      expect(requests().map((r) => r.id), containsAll(['web', 'app']));
      expect(alert()!.requests.map((r) => r.id), ['web']);
    });

    test('un INSERT de un pedido que ya está en la lista no repite nada', () async {
      await start();
      repository.emitRealtime(const RequestInserted('fresh'));
      await pumpEventQueue();
      expect(requests(), hasLength(2));
      expect(alert(), isNull);
    });

    test('varios pedidos seguidos se juntan en un aviso', () async {
      await start();
      repository
        ..insertFromRealtime(buildRequest(id: 'a', createdAt: DateTime.utc(2026, 10, 19, 11)))
        ..insertFromRealtime(buildRequest(id: 'b', createdAt: DateTime.utc(2026, 10, 19, 12)));
      await pumpEventQueue();
      expect(alert()!.requests.map((r) => r.id), ['b', 'a']);
    });

    test('al reconectar se relee la lista y se avisa lo que llegó sin aviso', () async {
      await start();
      repository.emitRealtime(const RealtimeConnected());
      await pumpEventQueue();
      final callsAfterFirstConnect = repository.fetchCalls;

      // Se corta la conexión y mientras tanto llega un pedido.
      repository
        ..emitRealtime(const RealtimeDisconnected())
        ..insertSilently(
          buildRequest(id: 'missed', createdAt: DateTime.utc(2026, 10, 19, 13)),
        )
        ..emitRealtime(const RealtimeConnected());
      await pumpEventQueue();

      expect(repository.fetchCalls, callsAfterFirstConnect + 1);
      expect(requests().first.id, 'missed');
      expect(alert()!.requests.single.id, 'missed');
    });

    /// Se corta la conexión, llegan [missed] sin aviso y vuelve.
    Future<void> reconnectAfter(List<ChefRequest> missed) async {
      repository.emitRealtime(const RealtimeConnected());
      await pumpEventQueue();
      repository.emitRealtime(const RealtimeDisconnected());
      for (final request in missed) {
        repository.insertSilently(request);
      }
      repository.emitRealtime(const RealtimeConnected());
      await pumpEventQueue();
    }

    test('al reconectar, una reserva a mano que llegó mientras tanto no avisa', () async {
      await start();
      await reconnectAfter([
        manualBooking('manual', DateTime.utc(2026, 10, 19, 13)),
      ]);

      expect(requests().first.id, 'manual');
      expect(alert(), isNull);
    });

    test('al reconectar, de lo que llegó mientras tanto se avisa solo el pedido de la web', () async {
      await start();
      await reconnectAfter([
        buildRequest(id: 'missed-web', createdAt: DateTime.utc(2026, 10, 19, 13)),
        buildRequest(
          id: 'missed-app',
          source: RequestSource.app,
          createdAt: DateTime.utc(2026, 10, 19, 14),
        ),
      ]);

      expect(requests().map((r) => r.id), containsAll(['missed-web', 'missed-app']));
      expect(alert()!.requests.map((r) => r.id), ['missed-web']);
    });

    test('la primera conexión no relee (la lista recién se cargó)', () async {
      await start();
      final calls = repository.fetchCalls;
      repository.emitRealtime(const RealtimeConnected());
      await pumpEventQueue();
      expect(repository.fetchCalls, calls);
    });

    test('al salir se cierra el canal y se descarta el aviso', () async {
      await start();
      repository.insertFromRealtime(buildRequest(id: 'x'));
      await pumpEventQueue();
      expect(alert(), isNotNull);

      await container.read(sessionControllerProvider.notifier).signOut();
      await pumpEventQueue();
      expect(requests(), isEmpty);
      expect(alert(), isNull);
      expect(repository.realtimeListeners, 0);
    });
  });

  group('visto', () {
    test('markSeen lo marca enseguida y guarda lo del servidor', () async {
      await start();
      await controller().markSeen('fresh');
      expect(repository.markedSeen, ['fresh']);
      expect(requests().firstWhere((r) => r.id == 'fresh').seenAt, repository.seenAt);
      expect(container.read(newRequestsCountProvider), 0);
    });

    test('si el servidor falla, vuelve a quedar como nuevo', () async {
      repository.failMarkSeen = true;
      await start();
      await controller().markSeen('fresh');
      expect(requests().firstWhere((r) => r.id == 'fresh').seenAt, isNull);
    });

    test('abrir un pedido visto no hace nada', () async {
      await start();
      await controller().markSeen('older');
      expect(repository.markedSeen, isEmpty);
    });

    test('abrir saca el pedido del aviso', () async {
      await start();
      repository.insertFromRealtime(buildRequest(id: 'x', createdAt: DateTime.utc(2026, 10, 19, 11)));
      await pumpEventQueue();
      await controller().open('x');
      expect(alert(), isNull);
      expect(repository.markedSeen, ['x']);
    });

    test('abrir un pedido que no estaba en la lista lo trae y lo marca', () async {
      await start();
      repository.insertSilently(buildRequest(id: 'deep-link'));
      await controller().open('deep-link');
      expect(requests().map((r) => r.id), contains('deep-link'));
      expect(repository.markedSeen, ['deep-link']);
    });
  });

  group('rechazo', () {
    test('pasa a rechazado (y visto)', () async {
      await start();
      await controller().reject('fresh');
      final rejected = requests().firstWhere((r) => r.id == 'fresh');
      expect(rejected.status, RequestStatus.rejected);
      expect(rejected.seenAt, testNow);
      expect(repository.rejected, ['fresh']);
    });

    test('si el pedido ya había cambiado, se actualiza y se avisa el conflicto', () async {
      await start();
      repository.requests['fresh'] = fresh.copyWith(status: RequestStatus.quoted);
      await expectLater(
        controller().reject('fresh'),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.conflict,
          ),
        ),
      );
      expect(
        requests().firstWhere((r) => r.id == 'fresh').status,
        RequestStatus.quoted,
      );
    });

    test('error de red: la lista no cambia', () async {
      repository.failReject = true;
      await start();
      await expectLater(controller().reject('fresh'), throwsA(isA<RequestsFailure>()));
      expect(requests().firstWhere((r) => r.id == 'fresh').status, RequestStatus.newRequest);
    });
  });

  group('deshacer el rechazo', () {
    final rejected = buildRequest(
      id: 'rejected',
      status: RequestStatus.rejected,
      seenAt: DateTime.utc(2026, 10, 18, 10),
      createdAt: DateTime.utc(2026, 10, 18, 9),
    );

    setUp(() => repository = FakeChefRequestsRepository([older, fresh, rejected]));

    test('vuelve a new y, como ya se había abierto, queda en Viste', () async {
      await start();
      await controller().undoReject('rejected');
      final restored = requests().firstWhere((r) => r.id == 'rejected');
      expect(restored.status, RequestStatus.newRequest);
      expect(restored.seenAt, DateTime.utc(2026, 10, 18, 10));
      expect(inboxTabOf(restored), InboxTab.seen);
      expect(repository.undoneRejects, ['rejected']);
      expect(alert(), isNull, reason: 'no es un pedido que acaba de llegar');
    });

    test('rechazar y deshacer deja el pedido como estaba (visto)', () async {
      await start();
      await controller().reject('fresh');
      await controller().undoReject('fresh');
      final request = requests().firstWhere((r) => r.id == 'fresh');
      expect(request.status, RequestStatus.newRequest);
      expect(request.seenAt, testNow);
      expect(container.read(newRequestsCountProvider), 0);
    });

    test('si ya no estaba rechazado, se actualiza y se avisa el conflicto', () async {
      await start();
      repository.requests['rejected'] = rejected.copyWith(status: RequestStatus.newRequest);
      await expectLater(
        controller().undoReject('rejected'),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.conflict,
          ),
        ),
      );
      expect(
        requests().firstWhere((r) => r.id == 'rejected').status,
        RequestStatus.newRequest,
      );
    });

    test('error de red: sigue rechazado', () async {
      repository.failUndoReject = true;
      await start();
      await expectLater(
        controller().undoReject('rejected'),
        throwsA(isA<RequestsFailure>()),
      );
      expect(
        requests().firstWhere((r) => r.id == 'rejected').status,
        RequestStatus.rejected,
      );
    });
  });

  group('marcar como cliente', () {
    // Dos pedidos de la misma persona y uno de otra.
    final second = buildRequest(id: 'second', createdAt: DateTime.utc(2026, 10, 17, 9));
    final other = buildRequest(
      id: 'other',
      clientId: '33333333-3333-4333-8333-333333333333',
      createdAt: DateTime.utc(2026, 10, 16, 9),
    );

    setUp(() => repository = FakeChefRequestsRepository([fresh, second, other]));

    test('pasa la ficha a cliente y lo refleja en todos sus pedidos', () async {
      await start();
      await controller().markClientAsCustomer('fresh');
      expect(repository.markedClients, [testClientId]);
      final byId = {for (final r in requests()) r.id: r};
      expect(byId['fresh']!.client.status, ClientStatus.trial);
      expect(byId['second']!.client.status, ClientStatus.trial);
      expect(byId['other']!.client.status, ClientStatus.prospect, reason: 'otra persona');
      expect(byId['fresh']!.canMarkClient, isFalse);
    });

    test('si la ficha ya no era un prospecto, se relee y se avisa el conflicto', () async {
      await start();
      // Otro dispositivo ya la marcó (la ficha es una sola: cambia en todos sus pedidos).
      for (final request in [fresh, second]) {
        repository.requests[request.id] = request.copyWith(
          client: request.client.copyWith(status: ClientStatus.active),
        );
      }
      await expectLater(
        controller().markClientAsCustomer('fresh'),
        throwsA(
          isA<RequestsFailure>().having(
            (f) => f.kind,
            'kind',
            RequestsFailureKind.conflict,
          ),
        ),
      );
      expect(
        requests().firstWhere((r) => r.id == 'fresh').client.status,
        ClientStatus.active,
      );
    });

    test('error de red: la lista no cambia', () async {
      repository.failMarkClient = true;
      await start();
      await expectLater(
        controller().markClientAsCustomer('fresh'),
        throwsA(isA<RequestsFailure>()),
      );
      expect(
        requests().map((r) => r.client.status).toSet(),
        {ClientStatus.prospect},
      );
    });
  });

  test('refresh relee y, si falla, deja la lista como estaba', () async {
    await start();
    repository.insertSilently(buildRequest(id: 'new-one', createdAt: DateTime.utc(2026, 10, 19, 13)));
    await controller().refresh();
    expect(requests().first.id, 'new-one');
    expect(alert(), isNull, reason: 'al actualizar a mano no hace falta aviso');

    repository.failFetch = true;
    await expectLater(controller().refresh(), throwsA(isA<RequestsFailure>()));
    expect(requests(), hasLength(3));
  });

  group('reserva a mano confirmada en este dispositivo (applyManualBooking)', () {
    // El pedido que arma la hoja con lo que ya sabe; el del servidor tiene
    // el contacto como lo guardó la base.
    final provisional = manualBooking('manual-1', testNow).copyWith(
      clientId: 'c-anna',
      client: const RequestClient(
        displayName: 'Anna Verdi',
        contactPhone: '+393471112222',
        status: ClientStatus.trial,
      ),
    );
    final saved = provisional.copyWith(
      client: provisional.client.copyWith(contactEmail: 'anna@example.test'),
    );
    final annaProspect = buildRequest(
      id: 'anna-web',
      clientId: 'c-anna',
      name: 'Anna Verdi',
      clientStatus: ClientStatus.prospect,
      createdAt: DateTime.utc(2026, 10, 17, 9),
    );

    test('la agrega enseguida, sin aviso, y la reemplaza al releerla', () async {
      await start();
      repository.failFetch = true;
      controller().applyManualBooking(provisional);
      expect(requests().first, provisional);
      expect(inboxTabOf(requests().first), InboxTab.bookings);
      expect(alert(), isNull);
      await pumpEventQueue();
      expect(requests().first, provisional, reason: 'la relectura falló');

      repository
        ..failFetch = false
        ..insertSilently(saved);
      controller().applyManualBooking(provisional);
      await pumpEventQueue();
      expect(requests().where((r) => r.id == 'manual-1').single, saved);
    });

    test('si llega el INSERT con el mismo id, no se duplica ni avisa', () async {
      await start();
      repository.failFetch = true;
      controller().applyManualBooking(provisional);
      await pumpEventQueue();
      repository
        ..failFetch = false
        ..insertFromRealtime(saved);
      await pumpEventQueue();
      expect(requests().where((r) => r.id == 'manual-1'), hasLength(1));
      expect(alert(), isNull);
    });

    test('si el INSERT llegó antes, queda el del servidor', () async {
      await start();
      repository.insertFromRealtime(saved);
      await pumpEventQueue();
      repository.failFetch = true;
      controller().applyManualBooking(provisional);
      await pumpEventQueue();
      expect(requests().where((r) => r.id == 'manual-1').single, saved);
    });

    test('la ficha prospecto pasa a trial en todos sus pedidos; las demás no', () async {
      repository.insertSilently(annaProspect);
      await start();
      repository.failFetch = true;
      controller().applyManualBooking(provisional);
      final byId = {for (final r in requests()) r.id: r};
      expect(byId['anna-web']!.client.status, ClientStatus.trial);
      expect(byId['anna-web']!.canMarkClient, isFalse);
      expect(byId['fresh']!.client.status, ClientStatus.prospect);
    });
  });

  test('chefRequestProvider: si la lista no cargó, lo pide solo', () async {
    repository.failFetch = true;
    await start();
    expect(container.read(chefInboxProvider).hasError, isTrue);
    await expectLater(
      container.read(chefRequestProvider('fresh').future),
      throwsA(isA<RequestsFailure>()),
    );

    // Vuelve la conexión: reintentar el detalle alcanza (sin recargar la lista).
    repository.failFetch = false;
    container.invalidate(chefRequestProvider('fresh'));
    expect((await container.read(chefRequestProvider('fresh').future))!.id, 'fresh');
  });

  test('chefRequestProvider: de la lista o, si no está, del servidor', () async {
    await start();
    expect((await container.read(chefRequestProvider('fresh').future))!.id, 'fresh');

    repository.insertSilently(buildRequest(id: 'outside'));
    expect((await container.read(chefRequestProvider('outside').future))!.id, 'outside');
    expect(await container.read(chefRequestProvider('missing').future), isNull);
  });
}

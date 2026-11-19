// El menú que eligió el cliente de un pedido, para el detalle: los platos de
// requests.wishes en orden, con sus nombres, sin consultar nada si no eligió,
// sin volver a pedirlos cuando el pedido cambia por otra cosa o se relee y sin
// reintentar solo si fallan.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/application/chosen_menu_provider.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chosen_menu.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

void main() {
  const lasagne = MenuDish(id: lasagneId, nameIt: 'Lasagne alla bolognese');
  const minestrone = MenuDish(
    id: minestroneId,
    nameIt: 'Minestrone di verdure',
  );

  late FakeChefRequestsRepository repository;
  late ProviderContainer container;

  /// Con [defaultRetry], el contenedor con el reintento por defecto de
  /// Riverpod, como en la app (los tests van sin reintentos).
  Future<void> start({bool defaultRetry = false}) async {
    container = ProviderContainer.test(
      retry: defaultRetry ? null : noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: chefUser),
        ),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        chefRequestsRepositoryProvider.overrideWithValue(repository),
        clockProvider.overrideWithValue(() => testNow),
      ],
    );
    container.listen(chefInboxProvider, (_, _) {});
    await pumpEventQueue();
  }

  /// Escucha el menú del pedido [id] (como el detalle) y espera el resultado.
  Future<AsyncValue<List<ChosenDish>>> menuOf(String id) async {
    container.listen(chosenMenuProvider(id), (_, _) {});
    await pumpEventQueue();
    return container.read(chosenMenuProvider(id));
  }

  setUp(() {
    repository = FakeChefRequestsRepository([
      buildRequest(
        id: 'with-menu',
        wishes: const [minestroneId, risottoId, lasagneId],
      ),
      buildRequest(id: 'without-menu'),
    ])..dishes.addAll({lasagneId: lasagne, minestroneId: minestrone});
  });

  test('sin platos elegidos: vacío y no consulta nada', () async {
    await start();
    expect((await menuOf('without-menu')).requireValue, isEmpty);
    expect(repository.dishCalls, isEmpty);
  });

  test('con platos: en el orden elegido, con los nombres de hoy y el borrado en su lugar', () async {
    await start();
    expect((await menuOf('with-menu')).requireValue, const [
      (id: minestroneId, dish: minestrone),
      (id: risottoId, dish: null),
      (id: lasagneId, dish: lasagne),
    ]);
    expect(repository.dishCalls, [
      [minestroneId, risottoId, lasagneId],
    ]);
  });

  test('marcar el pedido como visto (al abrir el detalle) no vuelve a pedir los nombres', () async {
    await start();
    await menuOf('with-menu');
    await container.read(chefInboxProvider.notifier).open('with-menu');
    await pumpEventQueue();

    expect(repository.markedSeen, ['with-menu']);
    expect(
      container.read(chosenMenuProvider('with-menu')).requireValue,
      hasLength(3),
    );
    expect(repository.dishCalls, hasLength(1));
  });

  test(
    'si no se pueden leer los nombres: error; invalidar reintenta',
    () async {
      repository.failDishes = true;
      await start();
      final failed = await menuOf('with-menu');
      expect(failed.error, isA<RequestsFailure>());

      repository.failDishes = false;
      container.invalidate(chosenMenuProvider('with-menu'));
      await pumpEventQueue();
      expect(
        container.read(chosenMenuProvider('with-menu')).requireValue,
        hasLength(3),
      );
      expect(repository.dishCalls, hasLength(2));
    },
  );

  // Supabase devuelve objetos nuevos en cada lectura: una reconexión de
  // Realtime o deslizar para actualizar traen los mismos ids en otra lista.
  test('releer la bandeja (reconexión o deslizar) no vuelve a pedir los nombres: si fallaran, siguen', () async {
    repository.freshCopies = true;
    await start();
    await menuOf('with-menu');
    expect(repository.dishCalls, hasLength(1));

    repository.failDishes = true;
    final inboxReads = repository.fetchCalls;
    repository
      ..emitRealtime(const RealtimeConnected())
      ..emitRealtime(const RealtimeConnected());
    await pumpEventQueue();
    await container.read(chefInboxProvider.notifier).refresh();
    await pumpEventQueue();

    expect(
      repository.fetchCalls,
      inboxReads + 2,
      reason: 'la reconexión y el deslizar releyeron la bandeja',
    );
    expect(repository.dishCalls, hasLength(1));
    final menu = container.read(chosenMenuProvider('with-menu'));
    expect(menu.hasError, isFalse);
    expect(menu.requireValue.map((chosen) => chosen.dish?.nameIt), [
      'Minestrone di verdure',
      null,
      'Lasagne alla bolognese',
    ]);
  });

  // En la app, Riverpod reintenta solo unas 10 veces (~38 s) con la barra de
  // carga: el detalle tiene que decir enseguida que falló, con «Riprova».
  test('con el reintento por defecto de Riverpod, el error llega enseguida y no reintenta solo', () async {
    repository.failDishes = true;
    await start(defaultRetry: true);
    final failed = await menuOf('with-menu');

    expect(failed.isLoading, isFalse);
    expect(failed.error, isA<RequestsFailure>());
    expect(repository.dishCalls, hasLength(1));
  });
}

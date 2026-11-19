// El menú que eligió el cliente de un pedido, para el detalle: los platos de
// requests.wishes en orden, con sus nombres, sin consultar nada si no eligió
// y sin volver a pedirlos cuando el pedido cambia por otra cosa.
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

  Future<void> start() async {
    container = ProviderContainer.test(
      retry: noRetry,
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
}

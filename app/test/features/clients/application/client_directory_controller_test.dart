// Directorio de fichas de «Nuova prenotazione»: se lee con la cocinera, queda
// en error si falla (y se reintenta invalidándolo) y la búsqueda lo filtra.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/clients/application/client_directory_controller.dart';
import 'package:radici/features/clients/data/clients_repository.dart';

import '../../../support/client_fixtures.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeClientsRepository clients;
  late ProviderContainer container;

  Future<void> start() async {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        clientsRepositoryProvider.overrideWithValue(clients),
      ],
    );
    // Como el elegir: algo lo escucha mientras está abierto.
    container.listen(clientPickerViewProvider, (_, _) {});
    await pumpEventQueue();
  }

  setUp(() {
    auth = FakeAuthRepository(user: chefUser);
    clients = FakeClientsRepository([
      buildClient(id: 'c-1', name: 'Chiara Rossi'),
      buildClient(id: 'c-2', name: 'Anna Verdi', phone: '+39 347 000 1111'),
    ]);
  });

  test('lee las fichas de la cocinera', () async {
    await start();
    expect(
      container.read(clientDirectoryProvider).requireValue.map((c) => c.id),
      ['c-1', 'c-2'],
    );
    expect(clients.fetchCalls, 1);
  });

  test('sin sesión de cocinera queda vacío y no llama al servidor', () async {
    auth = FakeAuthRepository();
    await start();
    expect(container.read(clientDirectoryProvider).requireValue, isEmpty);
    expect(clients.fetchCalls, 0);
  });

  test('si falla queda en error; invalidarlo lo vuelve a leer', () async {
    clients.fetchFailure = const ClientsFailure(ClientsFailureKind.unavailable);
    await start();
    expect(container.read(clientDirectoryProvider).error, isA<ClientsFailure>());
    expect(container.read(clientPickerViewProvider).hasError, isTrue);

    clients.fetchFailure = null;
    container.invalidate(clientDirectoryProvider);
    await pumpEventQueue();
    expect(container.read(clientDirectoryProvider).requireValue, hasLength(2));
    expect(clients.fetchCalls, 2);
  });

  test('la búsqueda filtra la vista; el total cuenta todas', () async {
    await start();
    container.read(clientSearchQueryProvider.notifier).set('347');
    final view = container.read(clientPickerViewProvider).requireValue;
    expect(view.matches.map((c) => c.id), ['c-2']);
    expect(view.total, 2);

    container.read(clientSearchQueryProvider.notifier).set('');
    expect(
      container.read(clientPickerViewProvider).requireValue.matches,
      hasLength(2),
    );
  });
}

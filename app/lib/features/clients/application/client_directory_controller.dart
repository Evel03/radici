// Directorio de fichas de «Nuova prenotazione»: se lee al abrir el elegir y
// vive mientras haya en la pila un elegir, un formulario «Nuova cliente» o una
// hoja de reserva a mano (los tres lo escuchan). La búsqueda lo filtra.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/clients/data/clients_repository.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/clients/domain/client_search.dart';

final clientDirectoryProvider =
    AsyncNotifierProvider.autoDispose<
      ClientDirectoryController,
      List<ChefClient>
    >(ClientDirectoryController.new);

class ClientDirectoryController extends AsyncNotifier<List<ChefClient>> {
  @override
  Future<List<ChefClient>> build() async {
    final chefId = ref.watch(
      currentChefProvider.select((chef) => chef?.chefId),
    );
    if (chefId == null) return const [];
    return ref.watch(clientsRepositoryProvider).fetchClients(chefId: chefId);
  }
}

/// Lo que se escribe en la búsqueda del elegir. Vuelve a vacío al cerrarlo.
final clientSearchQueryProvider =
    NotifierProvider.autoDispose<ClientSearchQuery, String>(
      ClientSearchQuery.new,
    );

class ClientSearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query;
}

/// La lista del elegir: el directorio ordenado y filtrado por la búsqueda.
final clientPickerViewProvider =
    Provider.autoDispose<AsyncValue<ClientPickerView>>((ref) {
      final query = ref.watch(clientSearchQueryProvider);
      return ref
          .watch(clientDirectoryProvider)
          .whenData((clients) => clientPickerView(clients, query: query));
    });

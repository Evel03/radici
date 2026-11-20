// El menú que eligió el cliente de un pedido (requests.wishes), con los
// nombres de los platos, para el detalle. Los ids salen del pedido
// (chefRequestProvider) y los nombres, del repositorio.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chosen_menu.dart';

/// Los platos que eligió el cliente del pedido [requestId], en el orden en
/// que los tildó, con sus nombres de hoy (un plato borrado, sin nombre).
/// Vacío si no eligió ninguno: entonces no consulta nada.
///
/// Depende de qué ids hay y en qué orden, no de la lista: marcar el pedido
/// como visto o releer la bandeja (reconexión de Realtime, deslizar para
/// actualizar), que trae listas nuevas con los mismos ids, no vuelve a pedir
/// los nombres. La lista de freezed (EqualUnmodifiableListView) se compara
/// por la lista de origen, no por el contenido, así que se seleccionan los ids
/// unidos en un texto (son uuid: no llevan comas).
///
/// Error ([RequestsFailure]) si no se pueden leer, enseguida y sin reintentar
/// solo: el detalle lo dice con «Riprova» (con el reintento por defecto de
/// Riverpod, la barra de carga seguiría unos 38 s).
final chosenMenuProvider = FutureProvider.autoDispose
    .family<List<ChosenDish>, String>((ref, requestId) async {
      final joined = await ref.watch(
        chefRequestProvider(requestId)
            .selectAsync((request) => request?.wishes.join(',') ?? ''),
      );
      if (joined.isEmpty) return const [];
      final wishes = joined.split(',');
      final found = await ref
          .watch(chefRequestsRepositoryProvider)
          .fetchMenuDishes(wishes);
      return chosenDishes(wishes, found);
    }, retry: (_, _) => null);

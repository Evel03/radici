// El menú que eligió el cliente de un pedido (requests.wishes), con los
// nombres de los platos, para el detalle. Los ids salen del pedido
// (chefRequestProvider) y los nombres, del repositorio.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chosen_menu.dart';

/// Los platos que eligió el cliente del pedido [requestId], en el orden en
/// que los tildó, con sus nombres de hoy (un plato borrado, sin nombre).
/// Vacío si no eligió ninguno: entonces no consulta nada. Solo depende de los
/// ids: marcar el pedido como visto no vuelve a pedir los nombres. Error
/// ([RequestsFailure]) si no se pueden leer.
final chosenMenuProvider = FutureProvider.autoDispose
    .family<List<ChosenDish>, String>((ref, requestId) async {
      final wishes = await ref.watch(
        chefRequestProvider(requestId)
            .selectAsync((request) => request?.wishes ?? const <String>[]),
      );
      if (wishes.isEmpty) return const [];
      final found = await ref
          .watch(chefRequestsRepositoryProvider)
          .fetchMenuDishes(wishes);
      return chosenDishes(wishes, found);
    });

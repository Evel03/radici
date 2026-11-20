// Aviso emergente "Nueva solicitud de …" mientras la app está abierta, solo
// para los pedidos sin abrir que llegan de la web. Lo arma
// ChefInboxController cuando llega un pedido por tiempo real (o al
// reconectar) y lo muestra NewRequestAlertListener.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';

part 'new_request_alert.freezed.dart';

/// Pedidos llegados que la cocinera todavía no vio ni descartó.
@Freezed(toStringOverride: false)
abstract class NewRequestAlert with _$NewRequestAlert {
  const factory NewRequestAlert({
    /// Del más reciente al más viejo; nunca vacía.
    required List<ChefRequest> requests,
  }) = _NewRequestAlert;

  const NewRequestAlert._();

  ChefRequest get latest => requests.first;

  @override
  String toString() => 'NewRequestAlert(${requests.length})';
}

final newRequestAlertProvider =
    NotifierProvider<NewRequestAlertController, NewRequestAlert?>(
      NewRequestAlertController.new,
    );

class NewRequestAlertController extends Notifier<NewRequestAlert?> {
  @override
  NewRequestAlert? build() {
    // Al salir o cambiar de usuario, el aviso pendiente se descarta.
    ref.watch(currentChefProvider.select((chef) => chef?.chefId));
    return null;
  }

  /// Suma al aviso los pedidos de [arrived] que avisan al llegar (sin abrir y
  /// de la web: [ChefRequest.alertsOnArrival]), sin repetir pedidos.
  void show(Iterable<ChefRequest> arrived) {
    final fresh = arrived.where((r) => r.alertsOnArrival).toList();
    if (fresh.isEmpty) return;
    var requests = state?.requests ?? const <ChefRequest>[];
    for (final request in fresh) {
      requests = upsertRequest(requests, request);
    }
    state = NewRequestAlert(requests: requests);
  }

  /// Saca un pedido del aviso (ya se abrió); sin pedidos, el aviso se cierra.
  void forget(String requestId) {
    final current = state;
    if (current == null) return;
    final rest = current.requests.where((r) => r.id != requestId).toList();
    state = rest.isEmpty ? null : NewRequestAlert(requests: rest);
  }

  void dismiss() => state = null;
}

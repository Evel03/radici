// Pedidos de la cocinera: una sola lista para la bandeja, la agenda y el
// detalle. Se carga al entrar, se mantiene al día con Realtime (INSERT en
// requests filtrado por su chef_id) y se vuelve a leer al reconectar, por si
// se perdió algún aviso mientras no había conexión.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mestolo/core/clock.dart';
import 'package:mestolo/features/auth/application/session_controller.dart';
import 'package:mestolo/features/requests/application/new_request_alert.dart';
import 'package:mestolo/features/requests/data/chef_requests_repository.dart';
import 'package:mestolo/features/requests/domain/chef_request.dart';
import 'package:mestolo/features/requests/domain/inbox.dart';

final chefInboxProvider =
    AsyncNotifierProvider<ChefInboxController, List<ChefRequest>>(
      ChefInboxController.new,
    );

/// Cantidad de pedidos nuevos (contador de la bandeja).
final newRequestsCountProvider = Provider<int>(
  (ref) => countNew(ref.watch(chefInboxProvider).value ?? const []),
);

/// Un pedido por id: de la lista si está; si no (enlace directo a un pedido
/// fuera de la lista, o la lista no se pudo cargar), se busca en el servidor.
final chefRequestProvider = FutureProvider.autoDispose
    .family<ChefRequest?, String>((ref, id) async {
      List<ChefRequest>? requests;
      try {
        requests = await ref.watch(chefInboxProvider.future);
      } on Object {
        // Sin lista: el detalle igual se puede ver pidiéndolo solo.
        requests = null;
      }
      final local = requests?.where((r) => r.id == id).firstOrNull;
      if (local != null) return local;
      return ref.read(chefRequestsRepositoryProvider).fetchRequest(id);
    });

class ChefInboxController extends AsyncNotifier<List<ChefRequest>> {
  /// El canal ya estuvo suscripto: un nuevo "conectado" es una reconexión.
  bool _connectedBefore = false;

  ChefRequestsRepository get _repository =>
      ref.read(chefRequestsRepositoryProvider);

  @override
  Future<List<ChefRequest>> build() async {
    final chefId = ref.watch(
      currentChefProvider.select((chef) => chef?.chefId),
    );
    if (chefId == null) return const [];
    final repository = ref.watch(chefRequestsRepositoryProvider);

    final subscription = repository
        .watchNewRequests(chefId: chefId)
        .listen(
          (event) => unawaited(_onRealtimeEvent(event, chefId)),
          // Los cortes llegan como RealtimeDisconnected; un error del stream
          // no tiene que tirar la lista.
          onError: (Object _) {},
        );
    ref.onDispose(subscription.cancel);

    return sortNewestFirst(await repository.fetchRequests(chefId: chefId));
  }

  Future<void> _onRealtimeEvent(
    RequestsRealtimeEvent event,
    String chefId,
  ) async {
    switch (event) {
      case RequestInserted(:final requestId):
        await _onInserted(requestId, chefId);
      case RealtimeConnected():
        final reconnected = _connectedBefore;
        _connectedBefore = true;
        if (reconnected) await _resync(chefId);
      case RealtimeDisconnected():
        // El cliente de Realtime reconecta solo; al volver se resincroniza.
        break;
    }
  }

  Future<void> _onInserted(String requestId, String chefId) async {
    final List<ChefRequest> current;
    try {
      current = await future;
    } on Object {
      // La carga inicial falló: el pedido aparece al reintentar.
      return;
    }
    if (current.any((r) => r.id == requestId)) return;

    final ChefRequest? request;
    try {
      request = await _repository.fetchRequest(requestId);
    } on RequestsFailure {
      if (ref.mounted) await _resync(chefId);
      return;
    }
    if (request == null || !ref.mounted) return;
    state = AsyncData(upsertRequest(state.value ?? current, request));
    ref.read(newRequestAlertProvider.notifier).show([request]);
  }

  /// Relee la lista después de una reconexión y avisa los pedidos que
  /// llegaron mientras tanto.
  Future<void> _resync(String chefId) async {
    final previous = state.value;
    final List<ChefRequest> fresh;
    try {
      fresh = sortNewestFirst(await _repository.fetchRequests(chefId: chefId));
    } on RequestsFailure {
      return;
    }
    if (!ref.mounted) return;
    state = AsyncData(fresh);
    if (previous == null) return;
    final known = {for (final r in previous) r.id};
    ref
        .read(newRequestAlertProvider.notifier)
        .show(fresh.where((r) => !known.contains(r.id)));
  }

  /// Vuelve a leer la lista (deslizar para actualizar). Si falla, la lista
  /// queda como estaba y se relanza [RequestsFailure] para avisar.
  Future<void> refresh() async {
    final chefId = ref.read(currentChefProvider)?.chefId;
    if (chefId == null) return;
    final fresh = await _repository.fetchRequests(chefId: chefId);
    if (!ref.mounted) return;
    state = AsyncData(sortNewestFirst(fresh));
  }

  /// La cocinera abrió el detalle: si el pedido no estaba en la lista se
  /// agrega, y se marca como visto.
  Future<void> open(String requestId) async {
    final List<ChefRequest> current;
    try {
      current = await future;
    } on Object {
      return;
    }
    if (!current.any((r) => r.id == requestId)) {
      final ChefRequest? fetched;
      try {
        fetched = await _repository.fetchRequest(requestId);
      } on RequestsFailure {
        return;
      }
      if (fetched == null || !ref.mounted) return;
      state = AsyncData(upsertRequest(state.value ?? current, fetched));
    }
    await markSeen(requestId);
  }

  /// Marca el pedido como visto. Se muestra visto enseguida; si el servidor
  /// falla, vuelve a quedar como nuevo.
  Future<void> markSeen(String requestId) async {
    final request = state.value?.where((r) => r.id == requestId).firstOrNull;
    if (request == null || request.seenAt != null) return;

    final now = ref.read(clockProvider)().toUtc();
    _update(requestId, (r) => r.copyWith(seenAt: now));
    ref.read(newRequestAlertProvider.notifier).forget(requestId);
    try {
      final seenAt = await _repository.markSeen(requestId);
      if (!ref.mounted) return;
      _update(requestId, (r) => r.copyWith(seenAt: seenAt));
    } on RequestsFailure {
      if (!ref.mounted) return;
      _update(requestId, (r) => r.copyWith(seenAt: null));
    }
  }

  /// Rechaza un pedido nuevo. Lanza [RequestsFailure] si no se pudo; si el
  /// pedido había cambiado de estado, antes se actualiza con lo del servidor.
  Future<void> reject(String requestId) async {
    try {
      await _repository.reject(requestId);
    } on RequestsFailure catch (failure) {
      if (failure.kind == RequestsFailureKind.conflict) {
        await _reload(requestId);
      }
      rethrow;
    }
    if (!ref.mounted) return;
    final now = ref.read(clockProvider)().toUtc();
    _update(
      requestId,
      (r) => r.copyWith(status: RequestStatus.rejected, seenAt: r.seenAt ?? now),
    );
  }

  Future<void> _reload(String requestId) async {
    try {
      final request = await _repository.fetchRequest(requestId);
      if (request == null || !ref.mounted) return;
      state = AsyncData(upsertRequest(state.value ?? const [], request));
    } on RequestsFailure {
      // Se queda la versión local; el próximo refresh la corrige.
    }
  }

  void _update(String requestId, ChefRequest Function(ChefRequest) change) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final r in current) r.id == requestId ? change(r) : r,
    ]);
  }
}

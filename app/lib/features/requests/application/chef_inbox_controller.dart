// Pedidos de la cocinera: una sola lista para la bandeja, la agenda y el
// detalle. Se carga al entrar, se mantiene al día con Realtime (INSERT en
// requests filtrado por su chef_id) y se vuelve a leer al reconectar, por si
// se perdió algún aviso mientras no había conexión. Desde acá también se
// rechaza (o se deshace) y se marca a la persona como clienta.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/requests/application/new_request_alert.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';

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

  /// Relee la lista después de una reconexión y pasa al aviso los pedidos que
  /// llegaron mientras tanto (avisa solo los de la web sin abrir:
  /// NewRequestAlertController.show).
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
    await _changeStatus(requestId, _repository.reject);
    if (!ref.mounted) return;
    final now = ref.read(clockProvider)().toUtc();
    _update(
      requestId,
      (r) => r.copyWith(status: RequestStatus.rejected, seenAt: r.seenAt ?? now),
    );
  }

  /// Deshace el rechazo: el pedido vuelve a `new` y, como ya se había abierto,
  /// queda en "Viste". Errores como en [reject].
  Future<void> undoReject(String requestId) async {
    await _changeStatus(requestId, _repository.undoReject);
    if (!ref.mounted) return;
    _update(
      requestId,
      (r) => r.copyWith(status: RequestStatus.newRequest),
    );
  }

  /// La persona del pedido pasó a ser clienta (su ficha deja de ser un
  /// prospecto y no se borra a los 90 días). Se refleja en todos sus pedidos.
  /// Lanza [RequestsFailure] si no se pudo; si la ficha ya había cambiado,
  /// antes se actualiza el pedido con lo del servidor.
  Future<void> markClientAsCustomer(String requestId) async {
    final request = state.value?.where((r) => r.id == requestId).firstOrNull;
    if (request == null) return;
    final clientId = request.clientId;
    try {
      await _repository.markClientAsCustomer(clientId);
    } on RequestsFailure catch (failure) {
      if (failure.kind == RequestsFailureKind.conflict) {
        await _reload(requestId);
      }
      rethrow;
    }
    if (!ref.mounted) return;
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final r in current)
        r.clientId == clientId
            ? r.copyWith(client: r.client.copyWith(status: ClientStatus.trial))
            : r,
    ]);
  }

  /// Se confirmó una reserva desde [requestId] (Edge Function chef): como en
  /// la base, el pedido pasa a `accepted` con sus [weeks] semanas (y visto) y
  /// la ficha, de prospecto a cliente, en todos sus pedidos. Pasa a la
  /// pestaña «Prenotazioni».
  void applyBooking(String requestId, {required int weeks}) {
    if (!ref.mounted) return;
    final current = state.value;
    final booked = current?.where((r) => r.id == requestId).firstOrNull;
    if (current == null || booked == null) {
      unawaited(_reload(requestId));
      return;
    }
    final now = ref.read(clockProvider)().toUtc();
    RequestClient asCustomer(RequestClient client) =>
        client.status == ClientStatus.prospect
        ? client.copyWith(status: ClientStatus.trial)
        : client;
    state = AsyncData([
      for (final r in current)
        if (r.id == requestId)
          r.copyWith(
            status: RequestStatus.accepted,
            weeks: weeks,
            seenAt: r.seenAt ?? now,
            client: asCustomer(r.client),
          )
        else if (r.clientId == booked.clientId)
          r.copyWith(client: asCustomer(r.client))
        else
          r,
    ]);
  }

  /// Se confirmó una reserva a mano (Edge Function chef): el pedido que creó
  /// el servidor (`source app`, `accepted` y visto) entra enseguida con lo que
  /// la hoja ya sabía ([provisional]), así está en «Prenotazioni» aunque la
  /// relectura tarde o falle; después se vuelve a leer y se reemplaza. Si ya
  /// estaba (llegó antes por tiempo real), queda el del servidor. Como en la
  /// base, una ficha prospecto pasa a cliente en todos sus pedidos. Sin
  /// aviso: no es un pedido nuevo.
  void applyManualBooking(ChefRequest provisional) {
    if (!ref.mounted) return;
    final current = state.value;
    if (current != null) {
      final updated = [
        for (final r in current)
          r.clientId == provisional.clientId &&
                  r.client.status == ClientStatus.prospect
              ? r.copyWith(client: r.client.copyWith(status: ClientStatus.trial))
              : r,
      ];
      final known = updated.any((r) => r.id == provisional.id);
      state = AsyncData(
        known ? updated : upsertRequest(updated, provisional),
      );
    }
    unawaited(_reload(provisional.id));
  }

  /// Vuelve a leer [requestId] del servidor (cambió en otro dispositivo). Si
  /// falla, queda lo local.
  Future<void> reload(String requestId) => _reload(requestId);

  Future<void> _changeStatus(
    String requestId,
    Future<void> Function(String id) change,
  ) async {
    try {
      await change(requestId);
    } on RequestsFailure catch (failure) {
      if (failure.kind == RequestsFailureKind.conflict) {
        await _reload(requestId);
      }
      rethrow;
    }
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

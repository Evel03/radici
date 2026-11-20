// Reglas de la bandeja "Richieste": qué pedido va en cada pestaña y en qué
// orden. Dart puro, sin Flutter.
import 'package:radici/features/requests/domain/chef_request.dart';

/// Pestañas de la bandeja (contrato §7), en el orden en que se muestran.
enum InboxTab {
  /// Sin abrir (`seen_at` null), no rechazados y que no son reservas.
  fresh,

  /// Ya abiertos, no rechazados y que no son reservas.
  seen,

  /// Reservas: pedidos `accepted` (una reserva es un pedido aceptado más sus
  /// sesiones, SPEC §4).
  bookings,

  /// Rechazados.
  rejected,
}

/// Pestaña a la que pertenece [request].
InboxTab inboxTabOf(ChefRequest request) {
  if (request.isRejected) return InboxTab.rejected;
  if (request.isBooking) return InboxTab.bookings;
  return request.seenAt == null ? InboxTab.fresh : InboxTab.seen;
}

/// Los pedidos de [tab], del más reciente al más viejo.
List<ChefRequest> requestsInTab(Iterable<ChefRequest> requests, InboxTab tab) =>
    sortNewestFirst(requests.where((r) => inboxTabOf(r) == tab));

/// Cantidad de pedidos nuevos (el número del contador).
int countNew(Iterable<ChefRequest> requests) =>
    requests.where((r) => r.isNew).length;

/// Del más reciente al más viejo; a igual fecha, por id para que el orden sea
/// estable.
List<ChefRequest> sortNewestFirst(Iterable<ChefRequest> requests) =>
    requests.toList()..sort((a, b) {
      final byDate = b.createdAt.compareTo(a.createdAt);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });

/// Reemplaza (por id) o agrega [request] y devuelve la lista ordenada.
List<ChefRequest> upsertRequest(
  Iterable<ChefRequest> requests,
  ChefRequest request,
) => sortNewestFirst([
  for (final r in requests)
    if (r.id != request.id) r,
  request,
]);

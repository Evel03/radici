// Pedido de abrir la bandeja «Richieste» en una pestaña: desde Hoy, «N
// nuove richieste» lleva a «Nuove» aunque la cocinera haya dejado la bandeja
// en otra. La bandeja vuelve a armar sus pestañas con cada pedido nuevo (ver
// InboxScreen); después se cambia de pestaña como siempre.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/requests/domain/inbox.dart';

/// Un pedido de pestaña. [serial] cambia en cada uno: dos pedidos de la misma
/// pestaña seguidos también cuentan.
final class InboxTabRequest {
  const InboxTabRequest({required this.serial, required this.tab});

  final int serial;
  final InboxTab tab;

  @override
  bool operator ==(Object other) =>
      other is InboxTabRequest && other.serial == serial && other.tab == tab;

  @override
  int get hashCode => Object.hash(serial, tab);
}

/// El último pedido de pestaña, o null si no hubo ninguno (la bandeja abre en
/// «Nuove»).
final inboxTabRequestProvider =
    NotifierProvider<InboxTabRequests, InboxTabRequest?>(
      InboxTabRequests.new,
    );

class InboxTabRequests extends Notifier<InboxTabRequest?> {
  @override
  InboxTabRequest? build() => null;

  /// La próxima vez que se vea, la bandeja abre en [tab].
  void show(InboxTab tab) =>
      state = InboxTabRequest(serial: (state?.serial ?? 0) + 1, tab: tab);
}

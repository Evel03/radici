// El presupuesto de un pedido para su detalle (SPEC 5.8, «Presupuesto»): se
// lee con la RLS de la cocina y se vuelve a leer cuando algo lo cambia desde
// este teléfono (mover o cancelar una de sus semanas, mandarlo con el menú de
// la semana 1, otro precio, retirarlo) y cuando cambia el estado del pedido
// (rechazarlo retira el presupuesto; una relectura de la bandeja trae lo que
// hizo la clienta, el cron u otro teléfono). Otro precio y retirarlo pasan por
// la Edge Function chef (QuoteCommands); prepararlo, por la hoja de
// «Confirmar reserva» (confirm_booking_controller.dart). Nada se loguea.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/quotes/domain/quote_api.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';

/// El último presupuesto del pedido [requestId] (null si nunca tuvo). Se
/// vuelve a leer si se mueve o se cancela una sesión y si cambia el estado
/// del pedido. Error ([QuoteFailure]) si no se puede leer, sin reintentar
/// solo: el detalle ofrece «Reintentar».
final requestQuoteProvider = FutureProvider.autoDispose
    .family<RequestQuote?, String>((ref, requestId) async {
      final chefId = ref.watch(
        currentChefProvider.select((chef) => chef?.chefId),
      );
      if (chefId == null) return null;
      // Una semana movida o cancelada cambia sus términos: hay que mandarlo de
      // nuevo, y el bloque lo dice.
      ref.listen(sessionChangesProvider, (_, change) {
        if (change != null) ref.invalidateSelf();
      });
      // El presupuesto sigue al pedido: rechazarlo lo retira (la base,
      // requests_close_open_quotes) y un pedido que siguió por otro lado (la
      // clienta aceptó o rechazó, venció, otro teléfono lo mandó) llega con la
      // relectura de la bandeja. Sin bucle: el presupuesto releído igual al de
      // antes no vuelve a leer el pedido (QuoteSection).
      ref.listen(
        chefRequestProvider(requestId)
            .select((request) => request.value?.status),
        (previous, next) {
          if (previous != null && next != null && previous != next) {
            ref.invalidateSelf();
          }
        },
      );
      return ref
          .watch(quotesRepositoryProvider)
          .fetchLatestQuote(chefId: chefId, requestId: requestId);
    }, retry: (_, _) => null);

/// El presupuesto se cerró entre dos lecturas: [before] estaba abierto y
/// [after], el mismo, ya no (lo aceptó o lo rechazó la clienta, venció o se
/// retiró, también al rechazar el pedido o confirmarlo sin presupuesto). Sus
/// semanas retenidas cambiaron (confirmadas o canceladas).
bool quoteClosedSince(RequestQuote? before, RequestQuote? after) =>
    before != null &&
    after != null &&
    after.id == before.id &&
    before.isOpen &&
    !after.isOpen;

/// El estado del pedido que corresponde a un presupuesto en [status] (lo que
/// hace la base al mandarlo, aceptarlo, rechazarlo, retirarlo o vencerlo):
/// si el pedido de la bandeja dice otra cosa, quedó viejo. Un borrador, uno
/// retirado o uno que venció sin salir dejan el pedido en `new`.
RequestStatus requestStatusFor(RequestQuote quote, QuoteStatus status) =>
    switch (status) {
      QuoteStatus.draft || QuoteStatus.withdrawn => RequestStatus.newRequest,
      QuoteStatus.sent ||
      QuoteStatus.changed ||
      QuoteStatus.changesRequested => RequestStatus.quoted,
      QuoteStatus.accepted => RequestStatus.accepted,
      QuoteStatus.declined => RequestStatus.declined,
      // Vencido por el plazo, el pedido pasa a `expired` cuando corre el cron
      // de la base (hasta 15 minutos): mientras tanto sigue `quoted`.
      QuoteStatus.expired =>
        !quote.wasSent
            ? RequestStatus.newRequest
            : quote.expiredAt == null
            ? RequestStatus.quoted
            : RequestStatus.expired,
    };

/// El pedido de la bandeja quedó viejo frente a su presupuesto: [current] es
/// `new` o `quoted` (los que cambia el presupuesto) y el presupuesto en
/// [status] dice otra cosa (salió desde otro teléfono, la clienta contestó,
/// venció o se retiró). Un pedido que siguió por otro camino (rechazado o
/// confirmado sin presupuesto: eso lo retiró) no.
bool requestLooksStale(
  RequestStatus current,
  RequestQuote quote,
  QuoteStatus status,
) =>
    (current == RequestStatus.newRequest || current == RequestStatus.quoted) &&
    requestStatusFor(quote, status) != current;

/// Los presupuestos con un cambio esperando al servidor (otro precio o
/// retirarlo): sus botones van deshabilitados (un segundo toque cruzaría los
/// pedidos).
final quoteBusyProvider = NotifierProvider<QuoteBusy, Set<String>>(
  QuoteBusy.new,
);

class QuoteBusy extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void _add(String id) => state = {...state, id};

  void _remove(String id) => state = {...state}..remove(id);
}

/// Otro precio y retirarlo, con la Edge Function chef. Si sale bien (o si la
/// base dice que ya cambió), el detalle vuelve a leer el presupuesto y el
/// pedido. Lanza [QuoteFailure].
final quoteCommandsProvider = Provider<QuoteCommands>(QuoteCommands.new);

class QuoteCommands {
  QuoteCommands(this._ref);

  final Ref _ref;

  QuotesRepository get _repository => _ref.read(quotesRepositoryProvider);

  /// Otro precio del servicio de todas las semanas de [quote], repartido
  /// entre sus semanas vivas. Si ya salió, hay que mandarlo de nuevo.
  Future<QuoteTerms> changePrice(RequestQuote quote, int serviceTotalCents) =>
      _run(
        quote,
        () => _repository.changePrice(
          quoteId: quote.id,
          serviceTotalCents: serviceTotalCents,
        ),
      );

  /// Retira [quote]: sus semanas retenidas se cancelan y el pedido vuelve a
  /// `new`. La agenda deja de mostrarlas.
  Future<WithdrawnQuote> withdraw(RequestQuote quote) async {
    final refreshSessions = agendaSessionsRefresher(_ref);
    final withdrawn = await _run(quote, () => _repository.withdraw(quote.id));
    if (refreshSessions != null) unawaited(refreshSessions());
    return withdrawn;
  }

  /// El presupuesto del detalle se cerró en otro lado ([quoteClosedSince]: lo
  /// aceptó o lo rechazó la clienta, venció, o se retiró al rechazar el
  /// pedido): sus semanas retenidas ya no lo están, así que la agenda (y con
  /// ella «Menús para mandar» en Hoy) las vuelve a leer.
  void closedElsewhere() {
    final refreshSessions = agendaSessionsRefresher(_ref);
    if (refreshSessions != null) unawaited(refreshSessions());
  }

  Future<T> _run<T>(RequestQuote quote, Future<T> Function() body) async {
    // Se toman antes de esperar: el detalle puede cerrarse mientras tanto.
    final inbox = _ref.read(chefInboxProvider.notifier);
    final busy = _ref.read(quoteBusyProvider.notifier);
    busy._add(quote.id);
    try {
      final result = await body();
      _refresh(quote, inbox);
      return result;
    } on QuoteFailure catch (failure) {
      switch (failure.kind) {
        case QuoteFailureKind.closed ||
            QuoteFailureKind.empty ||
            QuoteFailureKind.notFound ||
            QuoteFailureKind.conflict:
          // Cambió en otro lado (la clienta contestó, venció o lo cambió otro
          // teléfono): el detalle muestra lo de ahora.
          _refresh(quote, inbox);
        default:
          break;
      }
      rethrow;
    } finally {
      busy._remove(quote.id);
    }
  }

  void _refresh(RequestQuote quote, ChefInboxController inbox) {
    _ref.invalidate(requestQuoteProvider(quote.requestId));
    unawaited(inbox.reload(quote.requestId));
  }
}

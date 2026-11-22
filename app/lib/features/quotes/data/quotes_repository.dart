// El presupuesto de un pedido (SPEC 5.8, «Presupuesto»): se lee con la RLS de
// la cocina (`quotes`, sus semanas en `sessions` y sus envíos en
// `menu_sends`: la cocinera y sus colaboradores los leen, nadie los escribe
// desde la app) y se prepara, se le cambia el precio y se retira con la Edge
// Function `chef` (contrato docs/contracts/chef-api.md §14). Los estados de
// sesión solo cambian vía Edge Functions (CLAUDE.md): la app nunca escribe
// sesiones ni presupuestos.
//
// Como las reservas (bookings_repository.dart): el SDK manda la sesión de
// quien entró (Evelyn o un colaborador suyo) en `Authorization` y la clave
// publicable en `apikey`; la región va en la URL
// (`?forceFunctionRegion=eu-central-1`), nunca en la cabecera `x-region`, que
// el preflight de CORS no permite. El filtro explícito por chef_id es, como en
// las otras lecturas, para que una cocinera que además fuera clienta con
// cuenta no lea como suyo un presupuesto de otra cocina.
//
// Ningún error se loguea: puede traer la fila, con el mensaje de la clienta.
// Preparar uno falla con [BookingFailure] (la hoja es la de «Confirmar
// reserva», con sus mismos errores y dos propios); el precio y el retiro, con
// [QuoteFailure].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart'
    show
        BookingFailure,
        BookingFailureKind,
        SupabaseBookingsRepository,
        failureFromResponse;
import 'package:radici/features/quotes/domain/quote_api.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class QuotesRepository {
  /// El último presupuesto del pedido [requestId] (el abierto, si lo hay:
  /// uno por pedido), con todas sus semanas y el último envío que lo llevó;
  /// null si el pedido nunca tuvo. Lanza [QuoteFailure]
  /// ([QuoteFailureKind.unavailable]).
  Future<RequestQuote?> fetchLatestQuote({
    required String chefId,
    required String requestId,
  });

  /// POST chef/quotes: lo prepara (o, con `dryRun`, devuelve el estado de
  /// cada fecha sin escribir nada). Lanza [BookingFailure].
  Future<QuoteDraft> createQuote(CreateQuoteRequest request);

  /// POST chef/quotes/price: otro precio, repartido entre sus semanas vivas.
  /// Devuelve los términos de ahora. Lanza [QuoteFailure].
  Future<QuoteTerms> changePrice({
    required String quoteId,
    required int serviceTotalCents,
  });

  /// POST chef/quotes/withdraw: lo retira (sus semanas retenidas se cancelan
  /// y el pedido vuelve a `new`). Idempotente. Lanza [QuoteFailure].
  Future<WithdrawnQuote> withdraw(String quoteId);
}

final quotesRepositoryProvider = Provider<QuotesRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendQuotesRepository()
      : SupabaseQuotesRepository(client);
});

enum QuoteFailureKind {
  /// 409: ya está aceptado, rechazado, retirado o vencido.
  closed,

  /// 409: no le quedan semanas vivas (las cancelaron todas): no cambia de
  /// precio; se retira.
  empty,

  /// 404: el presupuesto no existe (para esta cocina).
  notFound,

  /// 403: el usuario no es la cocinera ni un colaborador suyo.
  forbidden,

  /// 401: sin sesión válida (vencida o cerrada).
  unauthorized,

  /// 400 y otros 4xx: un cuerpo que la app no debería mandar (o un precio
  /// fuera de rango).
  invalid,

  /// Otro 409.
  conflict,

  /// Sin conexión, la función o la base no responden, o una respuesta rota;
  /// también una lectura que falló. Se puede reintentar: otro precio igual o
  /// retirar otra vez no cambian nada.
  unavailable,
}

class QuoteFailure implements Exception {
  const QuoteFailure(this.kind);

  final QuoteFailureKind kind;

  /// Solo el tipo.
  @override
  String toString() => 'QuoteFailure(${kind.name})';
}

class SupabaseQuotesRepository implements QuotesRepository {
  SupabaseQuotesRepository(this._client);

  final SupabaseClient _client;

  /// Las rutas (functions.invoke arma `<url>/functions/v1/chef/quotes…`).
  static const String createFunction = 'chef/quotes';
  static const String priceFunction = 'chef/quotes/price';
  static const String withdrawFunction = 'chef/quotes/withdraw';

  /// Los envíos embebidos en cada presupuesto ([requestQuoteColumns]).
  static const String sendsPath = 'sends';

  @override
  Future<RequestQuote?> fetchLatestQuote({
    required String chefId,
    required String requestId,
  }) async {
    try {
      final row = await _client
          .from('quotes')
          .select(requestQuoteColumns)
          .eq('chef_id', chefId)
          .eq('request_id', requestId)
          // De sus envíos, solo el último que salió (el que lleva lo que
          // tiene la clienta y su respuesta), con el orden de la base.
          .not('$sendsPath.sent_at', 'is', null)
          .order('created_at', ascending: false)
          .order('sent_at', ascending: false, referencedTable: sendsPath)
          .order('id', ascending: false, referencedTable: sendsPath)
          .limit(1, referencedTable: sendsPath)
          .limit(1)
          .maybeSingle();
      return row == null ? null : RequestQuote.fromRow(row);
    } on Object {
      // Red, PostgREST o una fila rota: nada del detalle (puede traer el
      // mensaje de la clienta).
      throw const QuoteFailure(QuoteFailureKind.unavailable);
    }
  }

  @override
  Future<QuoteDraft> createQuote(CreateQuoteRequest request) async {
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        createFunction,
        body: request.toBody(),
        // Solo el parámetro: `region:` también mandaría x-region.
        queryParameters: const {
          'forceFunctionRegion': SupabaseBookingsRepository.functionRegion,
        },
      );
    } on FunctionsHttpException catch (error) {
      throw failureFromResponse(error.status, error.details);
    } on Object {
      // Red, relay de la plataforma o el token que no se pudo renovar.
      throw const BookingFailure(BookingFailureKind.unavailable);
    }
    try {
      final draft = QuoteDraft.fromResponse(response.data);
      if (draft.dryRun != request.dryRun ||
          draft.requestId != request.requestId) {
        throw const FormatException('Respuesta de otro pedido');
      }
      return draft;
    } on Object {
      // Una respuesta con otra forma: la hoja nunca queda esperando.
      throw const BookingFailure(BookingFailureKind.unavailable);
    }
  }

  @override
  Future<QuoteTerms> changePrice({
    required String quoteId,
    required int serviceTotalCents,
  }) => _invoke(
    priceFunction,
    quotePriceBody(quoteId: quoteId, serviceTotalCents: serviceTotalCents),
    (json) => quoteTermsFromPriceResponse(
      json,
      quoteId: quoteId,
      totalCents: serviceTotalCents,
    ),
  );

  @override
  Future<WithdrawnQuote> withdraw(String quoteId) =>
      _invoke(withdrawFunction, quoteWithdrawBody(quoteId), (json) {
        final withdrawn = withdrawnQuoteFromResponse(json);
        if (withdrawn.quoteId != quoteId) {
          throw const FormatException('Respuesta de otro presupuesto');
        }
        return withdrawn;
      });

  /// Llama a la función y lee su respuesta con [read].
  Future<T> _invoke<T>(
    String function,
    Map<String, Object> body,
    T Function(Object? json) read,
  ) async {
    final Object? data;
    try {
      final response = await _client.functions.invoke(
        function,
        body: body,
        queryParameters: const {
          'forceFunctionRegion': SupabaseBookingsRepository.functionRegion,
        },
      );
      data = response.data;
    } on FunctionsHttpException catch (error) {
      throw quoteFailureFromResponse(error.status, error.details);
    } on Object {
      throw const QuoteFailure(QuoteFailureKind.unavailable);
    }
    try {
      return read(data);
    } on Object {
      throw const QuoteFailure(QuoteFailureKind.unavailable);
    }
  }
}

/// Traduce una respuesta de error de /quotes/price o /quotes/withdraw
/// (contrato §3 y §14) a [QuoteFailure]. Del cuerpo solo se usa el código.
QuoteFailure quoteFailureFromResponse(int status, Object? body) {
  final map = body is Map ? body : const <Object?, Object?>{};
  final error = map['error'];
  switch (status) {
    case 400:
      return const QuoteFailure(QuoteFailureKind.invalid);
    case 401:
      return const QuoteFailure(QuoteFailureKind.unauthorized);
    case 403:
      return const QuoteFailure(QuoteFailureKind.forbidden);
    case 404:
      // Sin ese código, el 404 es de la plataforma (la función no está
      // desplegada): se puede reintentar más tarde.
      return error == 'quoteNotFound'
          ? const QuoteFailure(QuoteFailureKind.notFound)
          : const QuoteFailure(QuoteFailureKind.unavailable);
    case 409:
      return switch (error) {
        'quoteClosed' => const QuoteFailure(QuoteFailureKind.closed),
        'quoteEmpty' => const QuoteFailure(QuoteFailureKind.empty),
        _ => const QuoteFailure(QuoteFailureKind.conflict),
      };
    case >= 400 && < 500 when status != 429:
      return const QuoteFailure(QuoteFailureKind.invalid);
    default:
      return const QuoteFailure(QuoteFailureKind.unavailable);
  }
}

class _NoBackendQuotesRepository implements QuotesRepository {
  const _NoBackendQuotesRepository();

  @override
  Future<RequestQuote?> fetchLatestQuote({
    required String chefId,
    required String requestId,
  }) => Future.error(const QuoteFailure(QuoteFailureKind.unavailable));

  @override
  Future<QuoteDraft> createQuote(CreateQuoteRequest request) =>
      Future.error(const BookingFailure(BookingFailureKind.unavailable));

  @override
  Future<QuoteTerms> changePrice({
    required String quoteId,
    required int serviceTotalCents,
  }) => Future.error(const QuoteFailure(QuoteFailureKind.unavailable));

  @override
  Future<WithdrawnQuote> withdraw(String quoteId) =>
      Future.error(const QuoteFailure(QuoteFailureKind.unavailable));
}

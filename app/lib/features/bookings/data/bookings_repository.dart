// Reservas en la Edge Function `chef` (contrato docs/contracts/chef-api.md):
// la primera llamada de la app a una Edge Function. Los estados de sesión
// solo cambian vía Edge Functions (CLAUDE.md): la app crea la reserva con
// POST chef/bookings y nunca escribe sesiones.
//
// El SDK manda la sesión de quien entró (Evelyn o un colaborador suyo) en
// `Authorization: Bearer <token>` y la clave publicable en `apikey`. La región
// va en la URL (`?forceFunctionRegion=eu-central-1`, Frankfurt, como la web):
// la cabecera `x-region` no, porque el preflight de CORS no la permite
// (contrato §2).
//
// Ningún error se loguea: se traduce a [BookingFailure] (solo el tipo, la
// fecha del choque o el estado del pedido) y el resto se descarta.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class BookingsRepository {
  /// Confirma una reserva desde un pedido (o, con `dryRun`, devuelve el
  /// estado de cada fecha sin escribir nada). Lanza [BookingFailure].
  Future<BookingResult> createBooking(BookingRequest request);
}

final bookingsRepositoryProvider = Provider<BookingsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendBookingsRepository()
      : SupabaseBookingsRepository(client);
});

enum BookingFailureKind {
  /// 409: la semana de [BookingFailure.date] choca con otra sesión. No se
  /// creó nada.
  slotTaken,

  /// 409: la semana de [BookingFailure.date] ya tiene una sesión de la misma
  /// reserva. No se creó nada.
  weekTaken,

  /// 409: el pedido ya no está `new` ([BookingFailure.requestStatus] es su
  /// estado). No se creó nada.
  requestNotNew,

  /// 404: el pedido no existe (para esta cocinera).
  notFound,

  /// 403: el usuario no es la cocinera ni un colaborador suyo.
  forbidden,

  /// 401: sin sesión válida (vencida o cerrada).
  unauthorized,

  /// 400: algún campo no es válido ([BookingFailure.fields]).
  invalid,

  /// Otro 409.
  conflict,

  /// Sin conexión, la función o la base no responden, o una respuesta rota.
  /// Se puede reintentar con la misma clave: no duplica.
  unavailable,
}

class BookingFailure implements Exception {
  const BookingFailure(
    this.kind, {
    this.date,
    this.requestStatus,
    this.fields = const {},
  });

  final BookingFailureKind kind;

  /// La fecha del choque (slotTaken, weekTaken) o de la validación.
  final CalendarDate? date;

  /// Estado actual del pedido en requestNotNew (`accepted`, `rejected`…).
  final String? requestStatus;

  /// Campos con error en invalid.
  final Set<String> fields;

  /// Solo el tipo: ni la fecha ni el detalle.
  @override
  String toString() => 'BookingFailure(${kind.name})';
}

class SupabaseBookingsRepository implements BookingsRepository {
  SupabaseBookingsRepository(this._client);

  final SupabaseClient _client;

  /// La función y su ruta (functions.invoke arma `<url>/functions/v1/chef/bookings`).
  static const String bookingsFunction = 'chef/bookings';

  /// Frankfurt, como public-request (contrato public-request §2).
  static const String functionRegion = 'eu-central-1';

  @override
  Future<BookingResult> createBooking(BookingRequest request) async {
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        bookingsFunction,
        body: request.toBody(),
        // Solo el parámetro: `region:` también mandaría x-region.
        queryParameters: const {'forceFunctionRegion': functionRegion},
      );
    } on FunctionsHttpException catch (error) {
      throw failureFromResponse(error.status, error.details);
    } on Object {
      // Red, relay de la plataforma o el token que no se pudo renovar.
      throw const BookingFailure(BookingFailureKind.unavailable);
    }
    try {
      return BookingResult.fromResponse(response.data);
    } on Object {
      // Una respuesta con otra forma (FormatException o, si se escapara un
      // dato de otro tipo, un TypeError): la hoja nunca queda esperando.
      throw const BookingFailure(BookingFailureKind.unavailable);
    }
  }
}

/// Traduce una respuesta de error de la función (contrato §3) a
/// [BookingFailure]. Del cuerpo solo se usan el código, la fecha (si es una
/// fecha), el estado (si es uno de `request_status`) y los nombres de los
/// campos: nada más pasa.
BookingFailure failureFromResponse(int status, Object? body) {
  final map = body is Map ? body : const <Object?, Object?>{};
  final error = map['error'];
  final date = _dateOrNull(map['date']);
  switch (status) {
    case 400:
      final errors = map['errors'];
      return BookingFailure(
        BookingFailureKind.invalid,
        date: date,
        fields: errors is Map ? {...errors.keys.whereType<String>()} : const {},
      );
    case 401:
      return const BookingFailure(BookingFailureKind.unauthorized);
    case 403:
      return const BookingFailure(BookingFailureKind.forbidden);
    case 404:
      // Sin uno de estos códigos, el 404 es de la plataforma (la función no
      // está desplegada): se puede reintentar más tarde.
      return const {'requestNotFound', 'clientNotFound'}.contains(error)
          ? const BookingFailure(BookingFailureKind.notFound)
          : const BookingFailure(BookingFailureKind.unavailable);
    case 409:
      return switch (error) {
        'slotTaken' when date != null => BookingFailure(
          BookingFailureKind.slotTaken,
          date: date,
        ),
        'weekTaken' when date != null => BookingFailure(
          BookingFailureKind.weekTaken,
          date: date,
        ),
        'requestNotNew' => BookingFailure(
          BookingFailureKind.requestNotNew,
          requestStatus: _requestStatusOrNull(map['status']),
        ),
        _ => const BookingFailure(BookingFailureKind.conflict),
      };
    case >= 400 && < 500 when status != 429:
      // 405, 413, 415: un cuerpo que la app no debería mandar.
      return const BookingFailure(BookingFailureKind.invalid);
    default:
      return const BookingFailure(BookingFailureKind.unavailable);
  }
}

CalendarDate? _dateOrNull(Object? value) {
  if (value is! String) return null;
  try {
    return CalendarDate.parse(value);
  } on FormatException {
    return null;
  }
}

const Set<String> _requestStatuses = {
  'new',
  'quoted',
  'accepted',
  'declined',
  'rejected',
  'expired',
  'resolved',
};

String? _requestStatusOrNull(Object? value) =>
    _requestStatuses.contains(value) ? value as String : null;

class _NoBackendBookingsRepository implements BookingsRepository {
  const _NoBackendBookingsRepository();

  @override
  Future<BookingResult> createBooking(BookingRequest request) =>
      Future.error(const BookingFailure(BookingFailureKind.unavailable));
}

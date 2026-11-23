// El presupuesto en la Edge Function `chef` (contrato
// docs/contracts/chef-api.md §14): lo que la app manda a POST chef/quotes,
// /quotes/price y /quotes/withdraw, y lo que devuelven. Dart puro. Solo
// fechas, horas, minutos, centavos e ids: nada de la clienta.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';

part 'quote_api.freezed.dart';

/// Preparar el presupuesto de un pedido (POST chef/quotes): los campos de una
/// reserva desde un pedido, sin `type` ni `requestKey` (una clave de más es
/// un 400: el cuerpo lo arma solo la app).
@Freezed(fromJson: false, toJson: false)
abstract class CreateQuoteRequest with _$CreateQuoteRequest {
  const factory CreateQuoteRequest({
    required String requestId,

    /// De 1 a 8 fechas, una por semana (lunes a domingo) y en orden.
    required List<CalendarDate> dates,

    /// Llegada de todas las semanas; null solo en el dryRun.
    ClockTime? start,
    required int cookMinutes,
    int? portions,

    /// El servicio de todo el presupuesto, que se reparte entre las semanas
    /// (splitServiceCents). Obligatorio salvo en el dryRun.
    int? serviceTotalCents,
    @Default(false) bool dryRun,
  }) = _CreateQuoteRequest;

  const CreateQuoteRequest._();

  /// Lo mismo que la hoja mandaría para confirmar la reserva del pedido
  /// [booking] (requestId, fechas, hora, minutos, porciones y precio).
  factory CreateQuoteRequest.fromBooking(BookingRequest booking) {
    final requestId = booking.requestId;
    if (requestId == null) {
      throw ArgumentError.value(booking, 'booking', 'Sin pedido');
    }
    return CreateQuoteRequest(
      requestId: requestId,
      dates: booking.dates,
      start: booking.start,
      cookMinutes: booking.cookMinutes,
      portions: booking.portions,
      serviceTotalCents: booking.serviceTotalCents,
      dryRun: booking.dryRun,
    );
  }

  /// El cuerpo JSON (fechas "AAAA-MM-DD" y hora "HH:MM").
  Map<String, Object> toBody() => {
    'requestId': requestId,
    'dates': [for (final date in dates) date.toIso()],
    'start': ?start?.toHhMm(),
    'cookMinutes': cookMinutes,
    'portions': ?portions,
    'serviceTotalCents': ?serviceTotalCents,
    'dryRun': dryRun,
  };

  /// Solo cuántas fechas y si es un dryRun.
  @override
  String toString() =>
      'CreateQuoteRequest(dates: ${dates.length}, dryRun: $dryRun)';
}

/// Respuesta de POST chef/quotes: 200 en el dryRun (el estado de cada fecha,
/// como una reserva) y 201 creado (cada semana con su sesión `held`).
@Freezed(fromJson: false, toJson: false)
abstract class QuoteDraft with _$QuoteDraft {
  const factory QuoteDraft({
    required bool dryRun,

    /// null en el dryRun.
    String? quoteId,
    required String requestId,
    String? clientId,

    /// Hasta cuándo el borrador retiene las fechas (24 h, nunca más allá de
    /// la primera llegada); null en el dryRun.
    DateTime? holdUntil,

    /// En orden de fecha. Creado, el estado de cada una es [BookingDayStatus.ok]
    /// (la función dice `free`: quedó retenida; los avisos eran los del
    /// dryRun) y lleva su sesión.
    required List<BookingWeek> weeks,
  }) = _QuoteDraft;

  const QuoteDraft._();

  /// Lee el JSON de la respuesta. Lanza [FormatException] si no tiene la
  /// forma del contrato.
  factory QuoteDraft.fromResponse(Object? json) {
    if (json is! Map) throw const FormatException('Respuesta inválida');
    final dryRun = json['dryRun'];
    final quoteId = json['quoteId'];
    final requestId = json['requestId'];
    final clientId = json['clientId'];
    final holdUntil = json['holdUntil'];
    final weeks = json['weeks'];
    if (dryRun is! bool ||
        requestId is! String ||
        (clientId != null && clientId is! String) ||
        weeks is! List ||
        weeks.isEmpty ||
        weeks.length > maxQuoteWeeks) {
      throw const FormatException('Respuesta inválida');
    }
    final DateTime? hold;
    if (dryRun) {
      if (quoteId != null || holdUntil != null) {
        throw const FormatException('Respuesta inválida');
      }
      hold = null;
    } else {
      hold = holdUntil is String ? DateTime.tryParse(holdUntil) : null;
      if (quoteId is! String || quoteId.isEmpty || hold == null) {
        throw const FormatException('Respuesta inválida');
      }
    }
    return QuoteDraft(
      dryRun: dryRun,
      quoteId: quoteId as String?,
      requestId: requestId,
      clientId: clientId as String?,
      holdUntil: hold,
      weeks: [for (final week in weeks) _draftWeek(week, dryRun: dryRun)],
    );
  }

  /// La vista de reserva que usa la hoja (las mismas semanas).
  BookingResult toBookingResult({bool duplicate = false}) => BookingResult(
    dryRun: dryRun,
    duplicate: duplicate,
    requestId: requestId,
    clientId: clientId,
    weeks: weeks,
  );

  /// La sesión de la semana 1 (null en el dryRun).
  String? get firstSessionId => weeks.firstOrNull?.sessionId;
}

/// Una semana de la respuesta: en el dryRun, sin sesión y con el estado de la
/// fecha; creada, con su sesión, su hora y `free`.
BookingWeek _draftWeek(Object? json, {required bool dryRun}) {
  if (json is! Map) throw const FormatException('Semana inválida');
  final date = json['date'];
  final cookMinutes = json['cookMinutes'];
  final cents = json['serviceCents'];
  final sessionId = json['sessionId'];
  final raw = json['status'];
  final start = _timeOrNull(json['start']);
  final BookingDayStatus? status;
  if (dryRun) {
    status = BookingDayStatus.values.where((s) => s.name == raw).firstOrNull;
  } else {
    status = raw == 'free' ? BookingDayStatus.ok : null;
  }
  if (date is! String ||
      cookMinutes is! int ||
      cents is! int ||
      cents < 0 ||
      status == null ||
      (dryRun ? sessionId != null : sessionId is! String) ||
      (!dryRun && start == null)) {
    throw const FormatException('Semana inválida');
  }
  return BookingWeek(
    date: CalendarDate.parse(date),
    start: start,
    cookMinutes: cookMinutes,
    status: status,
    suggestedStart: _timeOrNull(json['suggestedStart']),
    serviceCents: cents,
    sessionId: sessionId as String?,
  );
}

/// "HH:MM" o null; cualquier otra cosa lanza [FormatException].
ClockTime? _timeOrNull(Object? value) =>
    value == null ? null : ClockTime.parse(value is String ? value : '');

/// Otro precio para un presupuesto abierto (POST chef/quotes/price).
Map<String, Object> quotePriceBody({
  required String quoteId,
  required int serviceTotalCents,
}) => {'quoteId': quoteId, 'serviceTotalCents': serviceTotalCents};

/// Retirar un presupuesto abierto (POST chef/quotes/withdraw).
Map<String, Object> quoteWithdrawBody(String quoteId) => {'quoteId': quoteId};

/// Los términos que devuelve POST chef/quotes/price para [quoteId] con el
/// precio [totalCents]. Lanza [FormatException] si no tiene la forma del
/// contrato, si es de otro presupuesto, con otro total o sin semanas.
QuoteTerms quoteTermsFromPriceResponse(
  Object? json, {
  required String quoteId,
  required int totalCents,
}) {
  final terms = QuoteTerms.tryParse(json);
  if (terms == null ||
      terms.quoteId != quoteId ||
      terms.totalCents != totalCents ||
      terms.weeks.isEmpty) {
    throw const FormatException('Respuesta inválida');
  }
  return terms;
}

/// Respuesta 200 de POST chef/quotes/withdraw: [already], ya estaba retirado
/// (no cambió nada); [cancelled], cuántas semanas retenidas se cancelaron.
typedef WithdrawnQuote = ({
  String quoteId,
  String requestId,
  bool already,
  int cancelled,
});

/// Lee la respuesta de POST chef/quotes/withdraw. Lanza [FormatException] si
/// no tiene la forma del contrato.
WithdrawnQuote withdrawnQuoteFromResponse(Object? json) {
  if (json is! Map) throw const FormatException('Respuesta inválida');
  final quoteId = json['quoteId'];
  final requestId = json['requestId'];
  final already = json['already'];
  final cancelled = json['cancelled'];
  if (quoteId is! String ||
      requestId is! String ||
      already is! bool ||
      cancelled is! int ||
      cancelled < 0 ||
      cancelled > maxQuoteWeeks) {
    throw const FormatException('Respuesta inválida');
  }
  return (
    quoteId: quoteId,
    requestId: requestId,
    already: already,
    cancelled: cancelled,
  );
}
